-- Buildat: builtin/kit/client_lua/environment.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- [KIT_ENVIRONMENT] The environment of the scene ("kit:environment",
-- kit/environment): the sky's colour (the fog's), the fog, the ambient
-- light and the sun by the hour, the clock going on here between the
-- server's word, and the weather drawn about the camera under open sky. The
-- app's own Zone and Sun are the ones changed (made when there are none)
-- and given back as they were when the environment goes. module.lua runs
-- this file with what it shares.
--   kit.environment() -> what it is now (nil: none)
-- [KIT_LIGHTING] (kit_plan 4o) And the composition's lighting, where the
-- app draws through Kit's views (kit.viewport: Workbench; skeldat's own
-- HDR path stays its own):
--   cartoon  today's look: LDR, the ambient, one sun, the fog
--   physical sky_render's path (HDR: exposure, bloom, tonemap), the light
--            of the hour by extensions/voxel_light's terms (physical_sky's
--            radiances), the voxels' albedo decoded (KitVoxel*Phys*.xml),
--            the voxel types that give light drawn as point lights
--   kit.physical() -> physical is drawn now
--   kit.lit_viewport(vp, role, finish, node): the lighting's render path
--     on a Kit view (role "play": the app's, which makes the look Kit's;
--     "editor": the editor's 3D and 2D), finish(rp) adding a view's own;
--     node: its camera's (nil: the app's), where the sky and the lamps
--     are looked at from
return function(K)
local M, O, log = K.M, K.O, K.log
local magic = require("buildat/extension/urho3d")
local network = require("buildat/extension/network")
local replicate = require("buildat/extension/replicate")

local env = {d = nil, orig = nil, zone = nil, sun = nil, light = nil,
		t = 0, h = 12, weather = "clear", open = true, check_t = 0}
function M.environment()
	return env.d
end

local function hex_colour(s, f)
	f = f or 1
	if type(s) ~= "string" or not s:match("^#%x%x%x%x%x%x$") then
		return nil
	end
	return magic.Color(tonumber(s:sub(2, 3), 16) / 255 * f,
			tonumber(s:sub(4, 5), 16) / 255 * f,
			tonumber(s:sub(6, 7), 16) / 255 * f)
end

local function env_nodes()
	local scene = replicate.main_scene
	if not scene then
		return false
	end
	if not env.zone then
		local zn = scene:GetChild("Zone")
		env.zone = zn and zn:GetComponent("Zone")
		if not env.zone then
			zn = scene:CreateChild("kit_env_zone")
			env.zone = zn:CreateComponent("Zone")
			env.zone.boundingBox = magic.BoundingBox(-100000, 100000)
			env.made_zone = zn
		end
		local sn = scene:GetChild("Sun")
		env.light = sn and sn:GetComponent("Light")
		if not env.light then
			sn = scene:CreateChild("kit_env_sun")
			env.light = sn:CreateComponent("Light")
			env.light.lightType = magic.LIGHT_DIRECTIONAL
			env.made_sun = sn
		end
		env.sun = sn
		local z, l = env.zone, env.light
		local function copy(c)
			return magic.Color(c.r, c.g, c.b)
		end
		env.orig = {ambient = copy(z.ambientColor), fog = copy(z.fogColor),
			fog_start = z.fogStart, fog_end = z.fogEnd,
			brightness = l.brightness, direction = sn.direction,
			colour = copy(l.color)}
	end
	return true
end

-- ---- [KIT_LIGHTING] The lighting: the render path of Kit's views
local LIT = {mode = "cartoon", views = {}, sky_render = nil, lamps = {},
		lamp_nodes = {}, scan = nil}

-- sky_render (and with it physical_sky and voxel_light), loaded when
-- physical is first drawn: cartoon costs nothing
local function sky_render()
	if not LIT.sky_render then
		local ok, err, sr = buildat.run_script_file("sky_render/init.lua")
		assert(ok and type(sr) == "table", "kit: sky_render: " ..
				tostring(err))
		LIT.sky_render = sr
	end
	return LIT.sky_render
end

-- physical is drawn where the app draws through Kit's views
function M.physical()
	return LIT.mode == "physical" and LIT.views.play ~= nil
end

local function lit_path(view)
	local rp
	if M.physical() then
		rp = sky_render().render_path(magic, view.base)
	else
		rp = view.base:Clone()
	end
	if view.finish then
		view.finish(rp)
	end
	view.vp.renderPath = rp
	LIT.grey = nil
end

function M.lit_viewport(vp, role, finish, node)
	local view = {vp = vp, base = vp.renderPath, finish = finish}
	LIT.views[role] = view
	LIT.view_node = node or O.camera
	if role == "play" then
		magic.renderer.HDRRendering = M.physical()
	end
	lit_path(view)
	if LIT.relight then
		LIT.relight()
	end
end

-- The lighting changed: the views' paths, HDR, the voxels' techniques
local function set_lighting(mode)
	mode = mode == "physical" and "physical" or "cartoon"
	if mode == LIT.mode then
		return false
	end
	LIT.mode = mode
	local phys = M.physical()
	log:info("kit: lighting " .. mode .. (phys and " (HDR, metered)" or
			LIT.views.play and "" or " (the app draws its own)"))
	if not LIT.views.play then
		return true
	end
	magic.renderer.HDRRendering = phys
	for _, view in pairs(LIT.views) do
		lit_path(view)
	end
	require("buildat/module/voxelworld").remesh_all()
	return true
end

-- The hue of the hour (skeldat's, its day colours alone): the zenith's
-- and the horizon's from night through dawn to day, day 0..1, lit the
-- hour's level; physical_sky's radiances
local function hue_of_hour(PHYS, t, lit)
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

local function clamp01(x)
	return math.max(0, math.min(1, x))
end

-- Toward the sun at the hour h: up from 6 to 18, east (+x) in the morning,
-- leaning south (-z); its height the sine of its elevation
local function sun_toward(h)
	local a = (h - 6) / 12 * math.pi
	local x, y, z = math.cos(a), math.sin(a), -0.4
	local l = math.sqrt(x * x + y * y + z * z)
	return x / l, y / l, z / l
end

-- ---- The sky: sky_render's dome (physical_sky's), drawn by its
-- PhysicalSky.glsl under physical and cartoon_sky's CartoonSky.glsl under
-- cartoon (Luanti's sky: the gradient, the sun's and the moon's squares,
-- the stars, a flat two-tone layer of cloud), the two taking the same
-- parameters (builtin/luanti's sky_dome.lua swaps them so too). What it
-- is before the hour says: voxel_shading's sky_defaults, Luanti's moon
-- and clouds (luanti_client's sky_model.lua's numbers: its cloud drift
-- is at its clouds' height, 120)
local SKY = {
	defaults = {zenith = {r = 0.13, g = 0.24, b = 0.58},
		horizon = {r = 0.55, g = 0.66, b = 0.84}, cloud_cover = 0.4,
		cloud_light = 1.0, sun_half = 0.075,
		sun_color = {r = 1.7, g = 1.66, b = 1.52}},
	schedule = {MOON_HALF = 0.048, CLOUD_ALPHA_DEFAULT = 229 / 255,
		CLOUD_SPEED_DEFAULT = {0, -2}, CLOUD_WIND_PER_NODE = 0.0054},
	CLOUD_HEIGHT = 120,
	STAR_DENSITY = 0.004,
	CLOUD = {r = 0.9, g = 0.92, b = 0.95},
	SUN_TINT = {r = 244 / 255, g = 125 / 255, b = 29 / 255},
	-- cartoon's zenith: the sky's colour deepened, the horizon's the fog's
	ZENITH = {0.55, 0.65, 0.9},
}
-- The dome, made once there is a sky to draw (where Kit draws the app's
-- view), its technique the mode's
local function sky_dome(on)
	local scene = replicate.main_scene
	on = on and LIT.views.play ~= nil
	if on and not LIT.dome and scene then
		LIT.dome = sky_render().new_dome(scene, {x = 0, y = -1, z = 0},
				SKY.defaults, log, SKY.schedule)
		LIT.techniques = {
			physical = magic.cache:GetResource("Technique",
					"physical_sky/PhysicalSky.xml"),
			cartoon = magic.cache:GetResource("Technique",
					"cartoon_sky/CartoonSky.xml")}
	end
	local dome = LIT.dome
	if not dome then
		return nil
	end
	dome:enabled(on)
	local mode = M.physical() and "physical" or "cartoon"
	if on and LIT.dome_mode ~= mode then
		LIT.dome_mode = mode
		dome.material:SetTechnique(0, LIT.techniques[mode])
	end
	return on and dome
end

local function bool(v, default)
	if type(v) == "boolean" then
		return v
	end
	return default
end

-- ---- [KIT_LIGHTING] The weather, a modifier on the environment's own
-- values (user, 2026-11-02): the parameters (and what the signals set)
-- are the scene with no weather, and a weather pushes some of them by
-- floors and factors, scaled by its intensity (0..1) -- an overcast scene
-- stays overcast when rain starts. clear leaves them all; storm's wind is
-- a floor in cells a second. Both lightings read the same final values.
local WEATHER_MOD = {
	clear = {},
	cloudy = {cover = 0.7, light = 0.9},
	rain = {cover = 0.8, light = 0.8},
	snow = {cover = 0.8, light = 0.8},
	storm = {cover = 0.95, light = 0.55, fog = 0.5, wind = 10},
}
local function weather_of(d)
	return WEATHER_MOD[d.weather] and d.weather or "clear"
end
local function intensity_of(d)
	return clamp01(tonumber(d.intensity) or 1)
end

-- The final values the environment's d says: the base under its weather
local function target(d)
	local m = WEATHER_MOD[weather_of(d)]
	local i = intensity_of(d)
	local function factor(f)
		return 1 - (1 - (f or 1)) * i
	end
	return {
		cover = math.max(clamp01(tonumber(d.cloud_cover) or 0.4),
				(m.cover or 0) * i),
		height = math.max(10, tonumber(d.cloud_height) or SKY.CLOUD_HEIGHT),
		wind = math.max(math.max(0, tonumber(d.cloud_wind_speed) or 2),
				(m.wind or 0) * i),
		dir = tonumber(d.cloud_wind_dir) or 180,
		light = factor(m.light), fog = factor(m.fog),
		sun = bool(d.sun, true), moon = bool(d.moon, true),
		stars = bool(d.stars, true),
	}
end

-- A change fades over weather_fade seconds (the clouds roll in): the
-- numbers from where they are to the new ones; the switches, the wind's
-- direction and the time at once
local FADE_KEYS = {"cover", "height", "wind", "light", "fog"}
local FADE = {cur = nil, from = nil, to = nil, t = 0, dur = 0}
local function fade_to(d, snap)
	local to = target(d)
	local same = FADE.to ~= nil
	for k, v in pairs(to) do
		same = same and FADE.to[k] == v
	end
	if same then
		return
	end
	local dur = math.max(0, tonumber(d.weather_fade) or 0)
	if snap or not FADE.cur or dur <= 0 then
		FADE.cur, FADE.to, FADE.dur = to, to, 0
		return
	end
	local from = {}
	for k, v in pairs(FADE.cur) do
		from[k] = v
	end
	FADE.from, FADE.to, FADE.t, FADE.dur, FADE.half = from, to, 0, dur,
			false
	log:info(string.format("kit: weather: fading to %s over %.1f s",
			weather_of(d), dur))
end

-- The values now: the fade's, the rest its target's
local function values()
	if not FADE.cur then
		fade_to(env.d, true)
	end
	local v = {}
	for k, x in pairs(FADE.to) do
		v[k] = x
	end
	for _, k in ipairs(FADE_KEYS) do
		v[k] = FADE.cur[k]
	end
	return v
end

-- How much sky the view sees (0..1): with the World's sky light on, the
-- column over the camera looked up, eased (skeldat's gate, by one ray);
-- off, the open sky everywhere
local GATE = {seen = 1, want = 1, t = 0}

-- How overcast the values are (0..1): a cover over a half grows into it
local function overcast(v)
	return clamp01((v.cover - 0.5) / 0.5)
end

-- [KIT_CLOUDS_DIM_SUN] How much of the sun's (or the moon's) direct light
-- the clouds let through, both lightings: all up to a cover of a half, none
-- at full, a smoothstep between -- cloudy's 0.7 0.65, rain's 0.8 0.35,
-- storm's 0.95 0.03. The weather's light factor is on top of it.
local function sun_through(v)
	local k = overcast(v)
	return 1 - k * k * (3 - 2 * k)
end

-- The sky's line in the log, when it changes
local function sky_log(mode, s)
	if FADE.dur > 0 then
		return
	end
	local line = string.format("kit: sky: %s, %.1f o'clock, sun %d, moon %d,"..
			" stars %.2f, clouds %.2f at %d, wind %.1f toward %d; %s %.2f:"..
			" light %.2f, fog %.2f, sun through %.2f", mode, env.h,
			s.sun and 1 or 0, s.moon and 1 or 0, s.stars, s.v.cover,
			math.floor(s.v.height + 0.5), s.v.wind, math.floor(s.v.dir + 0.5),
			weather_of(env.d), intensity_of(env.d), s.v.light, s.v.fog,
			sun_through(s.v))
	if line ~= LIT.sky_line then
		LIT.sky_line = line
		log:info(line)
	end
end

-- The sky of the hour, both modes: the sun, the moon and the stars where
-- they are and as switched, the clouds' cover and drift (their height
-- slows what is seen of a wind: the layer is drawn at one scale)
-- simplified: the height changes the drift alone; the shaders have no
-- height (a cloud height uniform, unset reading Luanti's 120, is the way)
local function sky_bodies(dome, v, tx, height, tz, day)
	local up, moon_up = clamp01(height / 0.05), clamp01(-height / 0.05)
	local s = {v = v, sun = v.sun and up > 0, moon = v.moon and moon_up > 0,
		stars = v.stars and (1 - day) * (1 - day) or 0, up = up,
		moon_up = moon_up}
	if dome then
		dome:set_sun_direction({x = -tx, y = -height, z = -tz})
		dome:set_moon_look(s.moon and SKY.schedule.MOON_HALF or 0)
		dome:set_star_look(v.stars and SKY.STAR_DENSITY or 0, nil, s.stars)
		dome:set_look(nil, nil, v.cover)
		local a = math.rad(v.dir)
		local k = v.wind * SKY.CLOUD_HEIGHT / v.height
		dome:set_clouds(nil, {math.sin(a) * k, math.cos(a) * k})
		local g = GATE.seen
		dome:set_outside(sky_render().physical_sky.outside(g))
	end
	return s
end

-- physical's light of the hour: the sun (or the moon) and the ambient by
-- voxel_light's terms, the fog the horizon's radiance, the dome
local function phys_light(v)
	local d = env.d
	local sr = sky_render()
	local PHYS = sr.PHYS
	local tx, height, tz = sun_toward(env.h)
	local day = clamp01((height + 0.15) / 0.3)
	local lit = (0.175 + 0.825 * day) ^ 2.2
	local zenith, horizon = hue_of_hour(PHYS, day, lit)
	zenith, horizon = sr.sky_radiance(zenith, horizon, height)
	-- Under cover the sky is the clouds' grey, and the meter's grey lower
	-- (physical_sky's overcast and middle_grey), so a storm reads dark
	local oc = overcast(v)
	zenith, horizon = sr.physical_sky.overcast(zenith, horizon, SKY.CLOUD, oc,
			sr.physical_sky.OVERCAST_DIM)
	local t = sr.terms(height, sr.dome(zenith, horizon))
	LIT.terms = t
	local grey = sr.physical_sky.middle_grey(sr.EXPOSURE.middle_grey, oc)
	if grey ~= LIT.grey then
		LIT.grey = grey
		for _, view in pairs(LIT.views) do
			view.vp.renderPath:SetShaderParameter("AutoExposureMiddleGrey",
					grey)
		end
	end
	local dome = sky_dome(true)
	local s = sky_bodies(dome, v, tx, height, tz, day)
	local a = t.ambient
	env.zone.ambientColor = magic.Color(a.r, a.g, a.b)
	-- [TUNNEL_SKY] where the view sees no sky the sky and the fog are the
	-- light of the place
	local enc, gate = sr.enclosed(t, GATE.seen)
	local fc = sr.physical_sky.fog(horizon, enc, gate)
	env.zone.fogColor = magic.Color(fc.r, fc.g, fc.b)
	local fe = (tonumber(d.fog_end) or env.orig.fog_end) * v.fog
	local fs = (tonumber(d.fog_start) or env.orig.fog_start) * v.fog
	env.zone.fogStart, env.zone.fogEnd = fs, math.max(fe, fs + 1)
	if s.sun then
		env.sun.direction = magic.Vector3(-tx, -height, -tz)
		env.light.brightness = t.sun * s.up * v.light * sun_through(v)
		env.light.color = magic.Color(t.sun_color.r, t.sun_color.g,
				t.sun_color.b)
	else
		env.sun.direction = magic.Vector3(tx, height, tz)
		env.light.brightness = s.moon and t.moon * s.moon_up * v.light *
				sun_through(v) or 0
		env.light.color = magic.Color(t.moon_color.r, t.moon_color.g,
				t.moon_color.b)
	end
	if dome then
		dome:set_look(zenith, horizon, nil)
		dome:set_dawn_glow(t.glow.r, t.glow.g, t.glow.b, t.glow_tint)
		local half = SKY.defaults.sun_half
		dome:set_sun_look(v.sun and half or 0, SKY.defaults.sun_color)
		dome:set_sun_radiance(sr.sun_disc(height, half, t.sun_color))
		dome:set_cloud_lit(sr.cloud_lit(SKY.CLOUD, zenith, horizon, height,
				1 - 0.8 * v.cover))
		dome:set_indoors(enc, 1)
	end
	sky_log("physical", s)
end

-- The light of the hour h (0 to 24): the sun up from 6 to 18
local function env_light()
	local d = env.d
	if not d or not env_nodes() then
		return
	end
	local v = values()
	if M.physical() then
		return phys_light(v)
	end
	local a = (env.h - 6) / 12 * math.pi
	local up = math.sin(a)
	local day = math.max(0, math.min(1, up * 2 + 0.3))
	local f = (0.25 + 0.75 * day) * v.light
	env.zone.fogColor = hex_colour(d.sky, f) or env.orig.fog
	-- Under cover the ambient greyer, half way to its grey at full
	local amb = hex_colour(d.ambient, 0.35 + 0.65 * day) or env.orig.ambient
	local oc = overcast(v)
	local grey = (amb.r + amb.g + amb.b) / 3
	local function g(c)
		return c + (grey - c) * 0.5 * oc
	end
	env.zone.ambientColor = magic.Color(g(amb.r), g(amb.g), g(amb.b))
	local fe = tonumber(d.fog_end) or env.orig.fog_end
	local fs = tonumber(d.fog_start) or env.orig.fog_start
	-- the fog's start closer than its end (today's storm: 0.4 and 0.5)
	fe, fs = fe * v.fog, fs * (1 - (1 - v.fog) * 1.2)
	env.zone.fogStart, env.zone.fogEnd = fs, math.max(fe, fs + 1)
	env.light.brightness = 0.8 * math.max(0, math.min(1, up * 1.5 + 0.1)) *
			v.light * sun_through(v)
	env.light.color = env.orig.colour
	env.sun.direction = magic.Vector3(-math.cos(a) * 0.8,
			-math.max(up, 0.15), 0.5)
	-- The sky: its horizon the fog's colour, its zenith the sky's colour
	-- deepened, the clouds lit by the hour
	local dome = sky_dome(true)
	local tx, height, tz = sun_toward(env.h)
	local s = sky_bodies(dome, v, tx, height, tz, day)
	if dome then
		local h = env.zone.fogColor
		local z = SKY.ZENITH
		local function zen(c, k)
			return c * (k + (0.95 - k) * oc)
		end
		dome:set_look({r = zen(h.r, z[1]), g = zen(h.g, z[2]),
				b = zen(h.b, z[3])}, {r = h.r, g = h.g, b = h.b}, nil)
		dome:set_dawn_glow(0, 0, 0, 0)
		dome:set_sun_look(v.sun and SKY.defaults.sun_half or 0, SKY.SUN_TINT)
		local c = SKY.CLOUD
		local k = (0.3 + 0.7 * day) * v.light
		dome.set_param("CloudColor", c.r * k, c.g * k, c.b * k)
		dome:set_indoors({r = 0.39, g = 0.39, b = 0.39}, 0.35 + 0.65 * day)
	end
	sky_log("cartoon", s)
end

LIT.relight = env_light

local function env_restore()
	if not env.zone then
		return
	end
	if env.made_zone then
		env.made_zone:Remove()
	else
		env.zone.ambientColor, env.zone.fogColor = env.orig.ambient,
				env.orig.fog
		env.zone.fogStart, env.zone.fogEnd = env.orig.fog_start,
				env.orig.fog_end
	end
	if env.made_sun then
		env.made_sun:Remove()
	else
		env.light.brightness = env.orig.brightness
		env.light.color = env.orig.colour
		env.sun.direction = env.orig.direction
	end
	env.zone, env.light, env.sun, env.made_zone, env.made_sun = nil, nil,
			nil, nil, nil
end

-- ---- The voxel types that give light, under physical: a point light at
-- each of the nearest, in voxel_light's lamp colour (its terms' lamp, a
-- glowstone's at a torch's faces) scaled by the type's level, its reach
-- the level in cells. Found by a scan of the cells about the camera, a
-- slice a frame.
-- simplified: within 8 cells across and 4 up and down of the camera, 8
-- lights at most, scanned again every half second; a world lit by lamps
-- farther off wants the mesher's lamp channel (the format has none:
-- [KIT_VOXEL_FORMAT]'s light_sky alone) or a lamp list the server keeps
local LAMP_R, LAMP_RY, LAMP_MAX = 8, 4, 8

local function view_pos()
	local n = LIT.view_node or O.camera
	return n and n.worldPosition
end

local function lamps_off()
	for _, n in ipairs(LIT.lamp_nodes) do
		n:Remove()
	end
	LIT.lamp_nodes, LIT.scan = {}, nil
end

local function lamps_place(found, p)
	table.sort(found, function(a, b)
		return (a[1] - p.x) ^ 2 + (a[2] - p.y) ^ 2 + (a[3] - p.z) ^ 2 <
			(b[1] - p.x) ^ 2 + (b[2] - p.y) ^ 2 + (b[3] - p.z) ^ 2
	end)
	local scene = replicate.main_scene
	local t = LIT.terms
	for i = 1, LAMP_MAX do
		local f = found[i]
		local n = LIT.lamp_nodes[i]
		if f and t and scene then
			if not n then
				n = scene:CreateChild("kit_lamp")
				local l = n:CreateComponent("Light")
				l.lightType = magic.LIGHT_POINT
				LIT.lamp_nodes[i] = n
			end
			n.enabled = true
			n.position = magic.Vector3(f[1], f[2], f[3])
			local l = n:GetComponent("Light")
			local k = f[4] / 15
			l.range = f[4]
			l.color = magic.Color(t.lamp.r * k, t.lamp.g * k, t.lamp.b * k)
		elseif n then
			n.enabled = false
		end
	end
	if #found ~= LIT.lamps_logged then
		LIT.lamps_logged = #found
		log:info("kit: lamps: " .. #found .. " lit about the camera")
	end
end

local function lamps_update(dt)
	if not M.physical() or not next(LIT.lamps) then
		if #LIT.lamp_nodes > 0 then
			lamps_off()
		end
		return
	end
	local p = view_pos()
	if not p then
		return
	end
	local voxelworld = require("buildat/module/voxelworld")
	local reg = voxelworld.get_voxel_registry()
	if not reg then
		return
	end
	local s = LIT.scan
	if not s then
		s = {wait = 0}
		LIT.scan = s
	end
	if not s.at then
		s.wait = s.wait - dt
		if s.wait > 0 then
			return
		end
		s.at = {math.floor(p.x + 0.5), math.floor(p.y + 0.5),
			math.floor(p.z + 0.5)}
		s.x, s.found, s.names = -LAMP_R, {}, s.names or {}
	end
	-- A slice of x a frame
	local c = s.at
	local stop = math.min(LAMP_R, s.x + 3)
	for x = s.x, stop do
		for y = -LAMP_RY, LAMP_RY do
			for z = -LAMP_R, LAMP_R do
				local id = reg:id_of(voxelworld.get_static_voxel(
						magic.Vector3(c[1] + x, c[2] + y, c[3] + z)))
				if id ~= 0 then
					local name = s.names[id]
					if name == nil then
						local def = reg:get_by_id(id)
						name = def and def.name.block_name or false
						s.names[id] = name
					end
					local level = name and (LIT.lamps[name] or
							LIT.lamps[name:match("^(.-):[^/]*$") or ""])
					if level then
						s.found[#s.found + 1] = {c[1] + x, c[2] + y,
							c[3] + z, level}
					end
				end
			end
		end
	end
	s.x = stop + 1
	if s.x > LAMP_R then
		lamps_place(s.found, p)
		s.at, s.wait = nil, 0.5
	end
end

-- The weather's drops: a billboard set about the camera, the drops in the
-- world's space falling and wrapped round it
local WEATHER_LOOK = {
	rain = {n = 400, size = {0.03, 0.6}, colour = {0.65, 0.7, 0.85, 0.55},
		speed = 16, drift = 0, face = "y"},
	storm = {n = 700, size = {0.04, 0.8}, colour = {0.6, 0.65, 0.8, 0.6},
		speed = 22, drift = 4, face = "y"},
	snow = {n = 500, size = {0.12, 0.12}, colour = {1, 1, 1, 0.9},
		speed = 2, drift = 0.6, face = "xyz"},
}
local WR = 14 -- the drops' box about the camera, half its side
local weather = {node = nil, set = nil, kind = nil, drops = {}}

-- The app's camera, kit.controls' or kit.editor's
local function camera_pos()
	return O.camera and O.camera.worldPosition
end

-- Open sky above p: no voxel there over the next 64 cells, known or not
local function open_sky(p)
	local voxelworld = require("buildat/module/voxelworld")
	local reg = voxelworld.get_voxel_registry()
	if not reg then
		return true
	end
	local x, z = math.floor(p.x + 0.5), math.floor(p.z + 0.5)
	for y = math.floor(p.y + 1.5), math.floor(p.y + 64) do
		local id = reg:id_of(voxelworld.get_static_voxel(
				magic.Vector3(x, y, z)))
		local def = id ~= 0 and reg:get_by_id(id)
		if def and def.physically_solid then
			return false, string.format("%s at (%d, %d, %d)",
					tostring(def.name and def.name.block_name), x, y, z)
		end
	end
	return true
end

local function weather_off()
	if weather.node then
		weather.node:Remove()
	end
	weather.node, weather.set, weather.kind, weather.drops, weather.n = nil,
			nil, nil, {}, nil
end

local function weather_on(kind, at, n)
	weather_off()
	local w = WEATHER_LOOK[kind]
	local scene = replicate.main_scene
	if not w or not scene then
		return
	end
	weather.kind, weather.n = kind, n
	weather.node = scene:CreateChild("kit_weather")
	local set = weather.node:CreateComponent("BillboardSet")
	set.numBillboards = n
	set.faceCameraMode = w.face == "y" and magic.FC_ROTATE_Y or
			magic.FC_ROTATE_XYZ
	local m = magic.Material:new()
	m:SetTechnique(0, magic.cache:GetResource("Technique",
			"Techniques/NoTextureUnlitAlpha.xml"))
	m:SetShaderParameter("MatDiffColor", magic.Color(w.colour[1],
			w.colour[2], w.colour[3], w.colour[4]))
	set.material = m
	weather.set = set
	log:info(string.format("kit: weather drawn: %s, %d drops about"..
			" (%.0f, %.0f, %.0f)", kind, n, at.x, at.y, at.z))
	for i = 0, n - 1 do
		local b = set:GetBillboard(i)
		b.size = magic.Vector2(w.size[1], w.size[2])
		b.enabled = true
		weather.drops[i] = {at.x + (math.random() * 2 - 1) * WR,
			at.y + (math.random() * 2 - 1) * WR,
			at.z + (math.random() * 2 - 1) * WR, math.random() * 6.28}
	end
end

local function wrap(v, c)
	return c + ((v - c + WR) % (2 * WR)) - WR
end

-- The sky's gate: with the World's sky light on, whether the view's
-- column is open (looked at four times a second), eased over half a second
local function gate_update(dt)
	if not M.sky_light() then
		GATE.want = 1
	else
		GATE.t = GATE.t - dt
		local p = GATE.t <= 0 and view_pos()
		if p then
			GATE.t = 0.25
			GATE.want = open_sky(p) and 1 or 0
		end
	end
	if GATE.seen ~= GATE.want then
		local k = math.min(1, dt * 2)
		GATE.seen = math.abs(GATE.want - GATE.seen) < 0.01 and GATE.want or
				GATE.seen + (GATE.want - GATE.seen) * math.max(k, 0.05)
		env_light()
	end
end

-- The fade's step: the values on toward the target, the light with them
local function fade_update(dt)
	if FADE.dur <= 0 then
		return
	end
	FADE.t = FADE.t + dt
	local k = math.min(1, FADE.t / FADE.dur)
	for _, key in ipairs(FADE_KEYS) do
		FADE.cur[key] = FADE.from[key] + (FADE.to[key] - FADE.from[key]) * k
	end
	if k >= 0.5 and not FADE.half then
		FADE.half = true
		log:info(string.format("kit: weather: half way: clouds %.2f,"..
				" light %.2f", FADE.cur.cover, FADE.cur.light))
	end
	if k >= 1 then
		FADE.cur, FADE.dur = FADE.to, 0
	end
	env_light()
end

local function env_update(dt)
	lamps_update(dt)
	local d = env.d
	if not d then
		return
	end
	fade_update(dt)
	gate_update(dt)
	if (tonumber(d.day_minutes) or 0) > 0 then
		env.h = (env.h + dt / 60 / d.day_minutes * 24) % 24
		env.t = env.t + dt
		if env.t >= 1 then
			env.t = 0
			env_light()
		end
	end
	local p = camera_pos()
	if not p then
		return
	end
	env.check_t = env.check_t - dt
	if env.check_t <= 0 then
		env.check_t = 0.25
		local open, what = open_sky(p)
		if open ~= env.open then
			env.open = open
			log:info("kit: weather " .. (open and "under open sky" or
					"under cover: " .. what))
		end
	end
	-- [KIT_LIGHTING] the intensity scales the drops: a drizzle to a downpour
	local n = math.floor((WEATHER_LOOK[d.weather] and
			WEATHER_LOOK[d.weather].n or 0) * intensity_of(d) + 0.5)
	local kind = n > 0 and env.open and d.weather or nil
	if kind ~= weather.kind or (kind and n ~= weather.n) then
		if kind then
			weather_on(kind, p, n)
		else
			weather_off()
		end
	end
	local w = kind and WEATHER_LOOK[kind]
	if not w or not weather.set then
		return
	end
	for i = 0, weather.n - 1 do
		local q = weather.drops[i]
		q[4] = q[4] + dt
		q[1] = wrap(q[1] + math.sin(q[4]) * w.drift * dt, p.x)
		q[2] = wrap(q[2] - w.speed * dt, p.y)
		q[3] = wrap(q[3] + math.cos(q[4] * 0.7) * w.drift * dt, p.z)
		weather.set:GetBillboard(i).position = magic.Vector3(q[1], q[2],
				q[3])
	end
	weather.set:Commit()
end

buildat.sub_packet("kit:environment", function(data)
	local d = network.parse_json(data)
	if type(d) ~= "table" then
		return
	end
	if d.on ~= true then
		if env.d then
			log:info("kit: environment: none")
		end
		env.d = nil
		weather_off()
		env_restore()
		sky_dome(false)
		LIT.lamps = {}
		set_lighting("cartoon")
		FADE.cur, FADE.to, FADE.dur = nil, nil, 0
		return
	end
	local was = env.d and env.d.weather
	local first = env.d == nil
	env.d = d
	env.h = (tonumber(d.time) or 12) % 24
	LIT.lamps = type(d.lamps) == "table" and d.lamps or {}
	-- At once when the environment comes or the lighting changes, else
	-- faded
	fade_to(d, set_lighting(d.lighting) or first)
	env_light()
	log:info(string.format("kit: environment: from the %s, %s, %.1f o'clock,"..
			" sky %s, fog %s-%s, gravity %s, weather %s, season %s",
			tostring(d.from), tostring(d.entity), env.h, tostring(d.sky),
			tostring(d.fog_start), tostring(d.fog_end), tostring(d.gravity),
			tostring(d.weather), tostring(d.season)))
	if d.weather ~= was then
		log:info("kit: weather " .. tostring(d.weather))
	end
end)
magic.SubscribeToEvent("Update", function(_, ev)
	env_update(ev:GetFloat("TimeStep"))
end)
end
-- vim: set noet ts=4 sw=4:
