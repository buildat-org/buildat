-- Buildat: apps/floorplanner/main/client_lua/daylight.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- **Daylight by place and time** ([FP_DAYLIGHT] in
-- doc/plan/floorplanner_plan.md): where the sun is for the plan's latitude,
-- north, date and hour; what the sun, the sky and the clouds are worth
-- then; the ground by the season; the sky drawn and rendered into a cube
-- for reflections; the render path that makes the frame an eye's. The
-- numbers are apps/vanilla's pbr path's (PHYS in its init.lua, fitted
-- against a path-traced reference), and the sky is
-- extensions/physical_sky's, which both Luanti clients draw in pbr too.
--
--   local daylight = buildat.run_script_file("main/daylight.lua")
local magic = require("buildat/extension/urho3d")
local M = {}
local rad, sin, cos = math.rad, math.sin, math.cos

--
-- Where the sun is
--
-- The direction towards the sun on the plan: physical_sky.sun_toward()
-- (floorplanner's, moved there for demo_hillclimb too [HILLCLIMB]), set
-- below where physical_sky is loaded

-- The eight points of the compass, for a direction on the plan
local POINTS = {"N", "NE", "E", "SE", "S", "SW", "W", "NW"}
-- Where a direction on the plan (dx, dz) points, as a compass point
function M.compass(north, dx, dz)
	-- The direction's own angle clockwise from the plan's up, less north's
	local a = (math.deg(math.atan2(dx, dz)) - north) % 360
	return POINTS[math.floor(a / 45 + 0.5) % 8 + 1]
end
-- Where north is on the plan view's screen, as a clock's hour
function M.north_clock(north)
	local h = math.floor(north / 30 + 0.5) % 12
	return h == 0 and 12 or h
end

-- "21.6." or "21.6" -> the day of the year; nil for no date
local MONTH_DAYS = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}
function M.parse_date(t)
	local d, m = tostring(t):match("^%s*(%d+)%.(%d+)%.?%s*$")
	d, m = tonumber(d), tonumber(m)
	if not d or m < 1 or m > 12 or d < 1 or d > MONTH_DAYS[m] then
		return nil
	end
	for i = 1, m - 1 do
		d = d + MONTH_DAYS[i]
	end
	return d
end
function M.date_text(day)
	local m = 1
	while m < 12 and day > MONTH_DAYS[m] do
		day = day - MONTH_DAYS[m]
		m = m + 1
	end
	return day .. "." .. m .. "."
end
-- "15:30" -> minutes; nil for no time
function M.parse_time(t)
	local h, mi = tostring(t):match("^%s*(%d+):(%d+)%s*$")
	h, mi = tonumber(h), tonumber(mi)
	if not h or h > 23 or mi > 59 then
		return nil
	end
	return h * 60 + mi
end
function M.time_text(minute)
	return string.format("%d:%02d", math.floor(minute / 60), minute % 60)
end

-- The time-lapse's speeds: minutes of the plan's day a second; and the
-- viewer's own clock for the hour (-1), and for the date too (-2)
M.LAPSES = {{"off", 0}, {"1 min/s", 1}, {"10 min/s", 10}, {"1 h/s", 60},
	{"real time", -1}, {"real date and time", -2}}

--
-- The ground by the season
--
-- A crude climate by latitude: the year's mean and its swing, coldest
-- about 20 January in the north and half a year on in the south. 65 N is
-- -14 in January and +18 in July, near Oulu's.
function M.temperature(lat, day)
	local a = math.abs(lat)
	local coldest = lat >= 0 and 20 or 202
	local phase = 2 * math.pi * (day - coldest) / 365
	return 28 - 0.4 * a - 0.25 * a * cos(phase), sin(phase) > 0
end
M.GROUNDS = {{"by season", 0}, {"green", 1}, {"yellow", 2}, {"snow", 3}}
local GROUND_RGB = {[1] = 0x55733a, [2] = 0xa8955a, [3] = 0xe8ecf0}
-- The ground's colour (0xRRGGBB) and which of green, yellow and snow it
-- is (1 to 3): `mode` a GROUNDS value, 0 by season.
-- Snow below -1 C, and in spring until the thaw has passed +2; bare and
-- yellow until +8 in spring and below +10 in autumn; green above.
function M.ground(lat, day, mode)
	if mode ~= 0 and GROUND_RGB[mode] then
		return GROUND_RGB[mode], mode
	end
	local t, warming = M.temperature(lat, day)
	if t < -1 or (warming and t < 2) then
		return GROUND_RGB[3], 3
	end
	if (warming and t < 8) or (not warming and t < 10) then
		return GROUND_RGB[2], 2
	end
	return GROUND_RGB[1], 1
end

--
-- What the sun and the sky are worth: extensions/physical_sky's PHYS, in
-- its units, with this app's own night and lamp over the games' picks
-- (a snapshot from before them: the night sky a third of theirs, no moon,
-- the lamp of before [TORCH_LIGHT]) and the clouds' albedo
--
local ok_phys, err_phys, physical_sky =
		buildat.run_script_file("physical_sky/init.lua")
if not ok_phys or type(physical_sky) ~= "table" then
	error("floorplanner: could not load physical_sky: " .. tostring(err_phys))
end
physical_sky = physical_sky.with({night_sky = 0.0001, lamp = 8,
		cloud = {r = 0.9, g = 0.92, b = 0.95}})
M.sun_toward = physical_sky.sun_toward
local PHYS = physical_sky.PHYS
M.PHYS = PHYS
local function lum(c)
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
end
local function scaled(c, to)
	local l = lum(c)
	if l <= 1e-9 then
		return {r = to, g = to, b = to}
	end
	return {r = c.r * to / l, g = c.g * to / l, b = c.b * to / l}
end
local function mix(a, b, k)
	return {r = a.r + (b.r - a.r) * k, g = a.g + (b.g - a.g) * k,
			b = a.b + (b.b - a.b) * k}
end

-- The sky ([FP_OVERCAST]): clear, or overcast
M.SKIES = {{"clear", 0}, {"overcast", 1}}
-- **An overcast sky's light**: this share of what the clear sky and the
-- sun put on the ground at the same hour (an overcast noon is some 10 to
-- 30 klux against a clear one's 100)
local OVERCAST_SHARE = 0.2

-- Everything the hour's light is, from the sine of the sun's elevation and
-- the ground's albedo (a colour 0..1): the sun's irradiance and colour,
-- the sky's zenith and horizon radiance, the ambient a face gets under
-- the open sky, and what lights the clouds. `overcast`: no sun, and the
-- sky the CIE standard overcast dome.
function M.light(h, ground, overcast)
	local s = {}
	s.sun = PHYS.sun(h)
	-- Rayleigh through an air mass of 1 / sin(elevation), luminance one
	local sr, sg, sb = PHYS.sun_rgb(h)
	s.sun_color = {r = sr, g = sg, b = sb}
	-- The sky: its day hues through a warm dawn to night's, at the games'
	-- radiance curves
	local f = PHYS.sky(h)
	local fh = PHYS.horizon(h)
	local dz, dh = PHYS.day_zenith, PHYS.day_horizon
	local dawn_h = {r = dh.r * 0.75, g = dh.g * 0.52, b = dh.b * 0.45}
	local night_z = {r = dz.r * 0.10, g = dz.g * 0.10, b = dz.b * 0.14}
	local zen_hue = f < 0.5 and mix(night_z, mix(night_z, dz, 0.5), f * 2) or
			mix(mix(night_z, dz, 0.5), dz, (f - 0.5) * 2)
	local hor_hue = fh < 0.5 and mix(night_z, dawn_h, fh * 2) or
			mix(dawn_h, dh, (fh - 0.5) * 2)
	s.zenith = scaled(zen_hue, PHYS.night_sky + (PHYS.sky_zenith -
			PHYS.night_sky) * f)
	s.horizon = scaled(hor_hue, PHYS.night_sky + (PHYS.sky_horizon -
			PHYS.night_sky) * fh)
	-- The dome a face sees: five parts zenith, one horizon, at the mean
	local dome_hue = {r = (5 * s.zenith.r + s.horizon.r) / 6,
			g = (5 * s.zenith.g + s.horizon.g) / 6,
			b = (5 * s.zenith.b + s.horizon.b) / 6}
	local mean = PHYS.night_sky + (PHYS.sky_zenith * PHYS.dome -
			PHYS.night_sky) * f
	local amb = scaled(dome_hue, mean)
	-- and a quarter of what the ground sends up (a wall sees it with half
	-- its view, a floor not at): its albedo times the sky and a third of
	-- the sun on it, over pi ([PBR_FIT]'s ground term)
	local up = s.sun * math.max(h, 0) / 3 / math.pi
	s.ambient = {r = amb.r + 0.25 * ground.r * (up * s.sun_color.r + mean / math.pi),
			g = amb.g + 0.25 * ground.g * (up * s.sun_color.g + mean / math.pi),
			b = amb.b + 0.25 * ground.b * (up * s.sun_color.b + mean / math.pi)}
	-- The clouds lit, vanilla's [CLOUD_LIGHT]: a thin noon cloud cloud_n
	-- times the zenith's patch
	local al = PHYS.cloud
	local noon_mean = (5 * PHYS.sky_zenith + PHYS.sky_horizon) / 6
	local k_sun = math.max(0, (PHYS.cloud_n * PHYS.sky_zenith * math.pi /
			lum(al) - noon_mean) / PHYS.sun(1))
	local e = s.sun * math.max(h, 0) * k_sun / math.pi
	s.cloud_sun = {r = al.r * e * s.sun_color.r, g = al.g * e * s.sun_color.g,
			b = al.b * e * s.sun_color.b}
	s.cloud_sky = {r = al.r * dome_hue.r / math.pi, g = al.g * dome_hue.g / math.pi,
			b = al.b * dome_hue.b / math.pi}
	if overcast then
		-- The CIE overcast dome, Lz (1 + 2 sin elevation) / 3, grey: the
		-- zenith three times the horizon, and Lz 7/9 pi on the ground
		local e = OVERCAST_SHARE * (s.sun * math.max(h, 0) + math.pi * mean)
		local lz = e * 9 / (7 * math.pi)
		local function grey(v)
			return {r = v, g = v, b = v}
		end
		local d = lz * 7 / 9
		s.overcast, s.sun = true, 0
		s.zenith, s.horizon = grey(lz), grey(lz / 3)
		s.ambient = {r = d + 0.25 * ground.r * d / math.pi,
				g = d + 0.25 * ground.g * d / math.pi,
				b = d + 0.25 * ground.b * d / math.pi}
		s.cloud_sun, s.cloud_sky = grey(0), grey(0)
	end
	return s
end

--
-- The sky, drawn and reflected
--
local SUN_HALF = 0.04
-- A skybox with physical_sky's shader and the cube the plan's surfaces
-- reflect.
-- sky:set(toward, h, light) each time the hour moves; sky:show(on).
function M.new_sky(scene)
	local node = scene:CreateChild("Sky")
	local box = node:CreateComponent("Skybox")
	box:SetModel(magic.cache:GetResource("Model", "Models/Box.mdl"))
	local mat = magic.Material:new()
	mat:SetTechnique(0, magic.cache:GetResource("Technique",
			"physical_sky/PhysicalSky.xml"))
	box.material = mat
	-- Every uniform the shader reads: an unset one reads as zero
	local V = magic.Vector3
	for name, v in pairs({SunTint = V(1, 1, 1), CloudColor = V(0.9, 0.92, 0.95),
			StarColor = V(0.9, 0.9, 1.0), SkyIndoors = V(0.39, 0.39, 0.39)}) do
		mat:SetShaderParameter(name, v)
	end
	for name, v in pairs({StarFade = 0, SunSize = SUN_HALF, SunOverexposure = 2.5,
			MoonSize = 0, StarDensity = 0, CloudCoverage = 0.35, CloudAlpha = 1,
			SunTextured = 0, MoonTextured = 0, SkyAutoDim = 0, SkyOvercast = 0,
			SkyOutside = 1}) do
		mat:SetShaderParameter(name, v)
	end
	mat:SetShaderParameter("CloudWind", magic.Vector2(0.004, 0))
	local cube = physical_sky.new_cube(mat)
	local self = {node = node, material = mat, cube = cube, texture = cube.texture}
	local last = nil
	function self:set(tx, ty, tz, h, light)
		local function v3(c)
			return V(c.r, c.g, c.b)
		end
		-- Overcast: no sun drawn, nor the band it paints on the horizon
		-- (the sun overhead), and no clouds -- the dome is the cloud
		-- layer's underside. Its gradient unphysical: the square root's is
		-- nearer the CIE dome's (straight in sin elevation) than the
		-- clear sky's, which is all zenith from 22 degrees up.
		-- simplified: the shader's gradient, not CIE's exactly (at 30
		-- degrees 0.71 of the way to the zenith, not 0.5); the upgrade is
		-- the formula in PhysicalSky.glsl behind cSkyOvercast
		local oc = light.overcast
		-- The cube again by the real sun: an overcast dome brightens with it
		self.want = string.format("%.3f %.3f %.3f %s", tx, ty, tz, tostring(oc))
		if oc then
			tx, ty, tz = 0, 1, 0
		end
		mat:SetShaderParameter("SunSize", oc and 0 or SUN_HALF)
		mat:SetShaderParameter("CloudCoverage", oc and 0 or 0.35)
		mat:SetShaderParameter("SkyOvercast", oc and 1 or 0)
		mat:SetShaderParameter("SunDirection", V(tx, ty, tz))
		mat:SetShaderParameter("SkyTop", v3(light.zenith))
		mat:SetShaderParameter("SkyHorizon", v3(light.horizon))
		local disc = math.min(light.sun / (math.pi * SUN_HALF * SUN_HALF), 65504)
		local sc = light.sun_color
		mat:SetShaderParameter("SunRadiance", V(disc * sc.r, disc * sc.g,
				disc * sc.b))
		mat:SetShaderParameter("CloudSun", v3(light.cloud_sun))
		mat:SetShaderParameter("CloudSky", v3(light.cloud_sky))
		-- The cube again when the sun has moved, four times a second at
		-- most: it is six renders, and a time-lapse moves it every frame
		self:flush()
	end
	-- The cube's render, when it is due; called each frame too, so the
	-- last move of a time-lapse is drawn once it stops
	function self:flush()
		local now = buildat.get_time_us()
		if self.want ~= last and now - (self.cube_t or 0) > 250000 then
			last, self.cube_t = self.want, now
			cube:update()
		end
	end
	function self:show(on)
		node.enabled = on
	end
	return self
end

--
-- The frame an eye's: HDR, metered, bloomed a little, tone mapped and
-- gamma encoded, as vanilla's pbr path (AUTO_EXPOSURE and its passes)
--
function M.pbr_render_path(rp)
	local function add(file)
		rp:Append(magic.cache:GetResource("XMLFile", file))
	end
	add("shaders/res/AutoExposureMean.xml")
	add("PostProcess/BloomHDR.xml")
	-- The light's colour adapted to and Khronos PBR Neutral, not vanilla's
	-- Uncharted2, whose shoulder is for its caves (user, 2026-10-01)
	add("main/fp_frame.xml")
	add("PostProcess/GammaCorrection.xml")
	rp:SetShaderParameter("BloomHDRThreshold", 1.2)
	rp:SetShaderParameter("BloomHDRMix", magic.Vector2(1.0, 0.03))
	rp:SetShaderParameter("AutoExposureAdaptRate", 0.6)
	-- **The meter's top** (user: snow in sunlight with some specular in
	-- saturation): a frame metered over 7 is exposed as if it were 7, so
	-- that a sunlit snow field is near white and its sheen past the tone
	-- map's white. Picked off a ladder of 3.5, 7 and 12 under an evening
	-- sun: 3.5 blew out the snow's shadows too, 12 left it grey.
	rp:SetShaderParameter("AutoExposureLumRange", magic.Vector2(0.003, 7.0))
	rp:SetShaderParameter("AutoExposureMiddleGrey", 0.18)
	return rp
end

--
-- **A room's daylight factor**: the share of the open sky's light its
-- surfaces get, from the glass it has over its floor (the rule of thumb,
-- about a fifth of the ratio), a little even with none
--
function M.daylight_factor(glass, floor)
	if floor <= 0 then
		return 1
	end
	return math.max(0.005, math.min(0.5, 0.2 * glass / floor))
end

-- The checks, at load
do
	local function elevation(lat, day, minute)
		local _, h = M.sun_toward(lat, 0, day, minute)
		return math.deg(math.asin(h))
	end
	local function near(a, b, eps, what)
		assert(math.abs(a - b) <= eps, what .. ": " .. a .. " against " .. b)
	end
	near(elevation(65, 80, 720), 25, 1, "equinox noon at 65 N")
	near(elevation(65, 172, 720), 48.4, 0.5, "midsummer noon at 65 N")
	near(elevation(65, 355, 720), 1.6, 0.5, "midwinter noon at 65 N")
	-- Noon due south: with north up the screen, south is down it (-Z)
	local x, _, z = M.sun_toward(65, 0, 80, 720)
	assert(math.abs(x) < 1e-6 and z < 0, "noon is due south")
	-- Morning in the east, which with north up is the screen's right (+X)
	x = M.sun_toward(65, 0, 172, 6 * 60)
	assert(x > 0, "morning in the east")
	-- North turned to the screen's right: noon's south is to the left
	x = M.sun_toward(65, 90, 80, 720)
	assert(x < -0.5, "north at 3 o'clock puts noon at 9")
	assert(M.compass(0, 0, 1) == "N" and M.compass(0, -1, 1) == "NW" and
			M.compass(90, 1, 0) == "N", "compass points")
	assert(M.north_clock(270) == 9 and M.north_clock(0) == 12, "the clock")
	assert(M.parse_date("21.6.") == 172 and M.date_text(172) == "21.6.",
			"dates")
	assert(M.parse_time("15:30") == 930 and M.time_text(930) == "15:30",
			"times")
	-- Oulu's year: snow in January, green in July, yellow late in April
	-- and in October
	assert(M.ground(65, 15, 0) == GROUND_RGB[3], "January snow at 65 N")
	assert(M.ground(65, 196, 0) == GROUND_RGB[1], "July green at 65 N")
	assert(M.ground(65, 290, 0) == GROUND_RGB[2], "October yellow at 65 N")
	assert(M.ground(20, 15, 0) == GROUND_RGB[1], "the tropics' green")
	-- Overcast: no sun, the zenith three times the horizon, grey, and
	-- darker than the clear noon
	local g = {r = 0.1, g = 0.1, b = 0.1}
	local c, o = M.light(0.8, g), M.light(0.8, g, true)
	assert(o.sun == 0 and math.abs(o.zenith.g - 3 * o.horizon.g) < 1e-9 and
			o.zenith.r == o.zenith.b and lum(o.ambient) < lum(c.ambient) +
			c.sun * 0.8 / math.pi, "overcast")
end

return M
-- vim: set noet ts=4 sw=4:
