-- Buildat: extensions/physical_sky/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- **The sky in HDR with exposure metering** ([LC_SKY_SHARED]): what pbr
-- (physical) clients draw over a world, and nothing of voxels. In it:
--   PHYS, the sun's and the sky's radiance at a sun height in the
--       path-traced reference's units ([PBR_FIT] term 1), and the picks
--       against the exposure's floor, which a client may override
--   the dawn and dusk glow, the sky's hue at a radiance, the fog, the
--       clouds' light, the sun's disc and the gate on how much sky is seen
--       (each takes "how much sky is seen" from the caller: voxel_light's
--       reading in a voxel world, a game's own elsewhere)
--   new_dome(), the sky drawn by PhysicalSky.glsl beside this file
--   new_cube(), that sky rendered into a cube for the reflections
-- Luanti's coloured sky, the parity modes', is not here
-- (extensions/luanti_client/res/LuantiSky.glsl).
--
-- **One source, two deliveries**: a client with no Buildat server behind it
-- takes it bundled,
--   local physical_sky = require("buildat/extension/physical_sky")
-- and a game takes its server's copy, served for a module that names it in
-- its meta.json's client_extensions, under the same names,
--   local physical_sky = select(3, buildat.run_script_file("physical_sky/init.lua"))
-- so it draws the version its server knows. A served resource name wins
-- over the bundled file of that name, so the shader follows the same way.
local magic = require("buildat/extension/urho3d")

local M = {}
-- The interface the sandbox's require hands out
M.safe = M

local function clamp01(v)
	return v < 0 and 0 or (v > 1 and 1 or v)
end
local function lum(c) return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b end

-- [PBR_FIT] term 1 (from extensions/luanti_client/res/sky_model.lua since
-- [LC_SKY_SHARED], from apps/vanilla before that): the sun and the sky are
-- in the path-traced reference's units,
-- read off its EXRs (doc/plan/rendering_plan.md, the fit's first term);
-- vanilla's SUN_BRIGHTNESS, MOON_BRIGHTNESS, SKY_AMBIENT and NIGHT_AMBIENT
-- are the parity modes' alone. The metering takes the absolute scale;
-- what these set is the ratio of sun to sky to moon, which is what
-- contrast is made of.
--   sun_e0, sun_tau  the sun's irradiance normal to it, E0 * exp(-tau /
--                    sin(elevation)): 170 at 64 degrees, which puts the
--                    render's sky patch over its sunlit snow at 10:00
--                    (sky_to_sun 0.25) once the snow's albedo is read
--                    decoded, and 93 at ten degrees, which is
--                    what its block top at 05:45 reads (1.9, 1.4, 1.0)
--                    off an albedo of 0.3 with the Rayleigh sun and a
--                    dome of 1.5 solved together (dawn_sun_dirt)
--   sky_zenith,      the sky's radiance at the zenith and the horizon
--   sky_horizon      by day: the render's 13:00 reads 4.9 near the
--                    zenith, 7.7 thirty degrees up, 12 at the horizon;
--                    fading over the last twelve degrees of the sun's
--                    elevation
--   bounce           light off the surroundings where the sky does not
--                    reach, as a share of the sky's mean (term 2)
--   ground           the ground's albedo, for what the lower hemisphere
--                    of a face outdoors sees: dirt and grass, warm
--   moon_e           the moon lamp's irradiance, the render's own
--   night_sky        what the sky is with the sun down: a floor for
--                    airglow, since Nishita gives none and the night's
--                    target is a sky under a fortieth of moonlit snow
-- simplified: the sky keeps Luanti's hue at this radiance, and the sun
-- its colour below; the colours are the terms after this one.
local PHYS = {sun_e0 = 195, sun_tau = 0.127, sky_zenith = 4.5,
		-- the moon at three times lunar irradiance, the user's pick off
		-- the x1 | x3 | x5 sheet (2026-09-20, [NIGHT_LIGHT]); the render's
		-- MOON_FACTOR is the same 3. And three times that (user,
		-- 2026-10-08, [CAVE_EXPOSURE_FLOOR]): the moonlit field brighter
		-- against the exposure's floor, which a sealed cave is not
		sky_horizon = 12.0, moon_e = 0.0025 * 3 * 3,
		-- the night sky at the user's pick off the 0.00002 | 0.00005 | 0.0002
		-- ladder (2026-09-20, [NIGHT_LIGHT]), the render's NIGHT_SKY; three
		-- times it with the moon (2026-10-08)
		night_sky = 0.0001 * 3,
		-- [CAVE_AO]'s floor: a constant light under the ambient so a sealed
		-- cave keeps its corners, the same at every hour. 0.04 was the
		-- user's pick of 2026-09-25; 0.005 since [CAVE_EXPOSURE_FLOOR]
		-- (2026-10-09), so a sealed cave is darker than a moonlit field:
		-- pbr_pair's closed cave reads 21.6/255 (0.01 read 27.7)
		cave_floor = 0.005,
		-- dome 0.9 -> 1.2 (2026-09-21, [PBR_FIT] a): the open-sky contrast
		-- read 4.5 against the render's 2.8 and snow's 13.6 against 11.2;
		-- at 1.2 snow's is 10.7 and its shade reads 1.0, dirt's 4.0; 1.5
		-- overshot snow's shade (1.13) and the pit (1.73). The tables are
		-- under local/options_for_PBR_FIT_viewport/probes_dome_*.txt
		-- ground x1.5 (2026-09-21 22:15, [PBR_FIT] a): the open-sky
		-- contrast 4.0 -> 3.19 against 2.81, the open shaded dirt face
		-- 0.53 -> 0.66 of the render's, the small cave's lit wall 0.38 ->
		-- 0.47 and both falloffs nearer; snow untouched. The shade's blue
		-- lags its red (0.5 against 0.66): the ground's hue is the next
		-- rung. probes_ground_075_kept.txt beside the dome tables.
		-- lamp 8 -> 1.5 ([TORCH_LIGHT], 2026-10-11) with the falloff
		-- counted from a torch's level: 1.5, 0.41, 0.14 at one, three and
		-- six nodes from a torch, where 8 over the old distance from
		-- fifteen gave 1.45, 0.37, 0.12 on the open faces the user saw
		-- lit right. A glowstone's own faces drop from 8 to 1.5. vp8's
		-- lamp_wall reads 2.8/4.2/7.3 of the render at 1, 2.2/3.5/6.7 at
		-- 0.3, 1.2/2.0/3.9 at 0.1, grey at all three: its ceiling has a
		-- nibble of a few, round the ledge, so no lamp level fits it
		-- ([LAMP_REF]'s finding, 2026-09-18).
		bounce = 0.15, lamp = 1.5, dome = 1.2, ground = {r = 0.75, g = 0.66, b = 0.45}, -- doubled 2026-09-19 with groundSeen cubed,
		-- the transmitted light through a leaf, over Lambert through its
		-- colour ([PBR_FIT] 3b, canopy_dawn)
		translucency = 1.0,
		-- how bright a thin noon cloud is against the sky's zenith patch:
		-- picked by the user off a ladder of 1.5 to 20 ([CLOUD_LIGHT],
		-- 2026-09-19); BUILDAT_SKY_CLOUD_N overrides
		cloud_n = 8,
		day_zenith = {r = 0.57, g = 0.76, b = 1.0},
		-- the horizon just over the sea at 13:00 reads (14.7, 14.9, 15.0)
		-- in the render: white, not Luanti's pale blue
		day_horizon = {r = 0.99, g = 0.995, b = 1.0}}
-- How far under our horizon the sun still lights the clouds: the dip of
-- the horizon from 7 km up, acos(R / (R + h)), in sine
PHYS.cloud_dip = 0.047
-- **The rules that read PHYS**, made over a PHYS and onto a table: the
-- module's own below, and M.with()'s copies, so an app's overrides reach
-- every function that reads them rather than a copy nothing reads.
local function bind(PHYS, M)
	-- The sky's radiance factor at a sun height (sin elevation): full by
	-- day, gone over the last twelve degrees, the floor below
	-- The zenith and the dome go first: at ten degrees the render's block
	-- top is lit by a sun of about 74 over a dome of about 1.5, a third of
	-- noon's, while its horizon band is still 9. The horizon keeps the old
	-- short fade.
	function PHYS.sky(height)
		return math.max(0, math.min(1, (height + 0.02) / 0.55))
	end
	function PHYS.horizon(height)
		return math.max(0, math.min(1, (height + 0.05) / 0.21))
	end
	function PHYS.sun(height)
		if height <= 0 then
			return 0
		end
		return PHYS.sun_e0 * math.exp(-PHYS.sun_tau / math.max(height, 0.05))
	end
	-- The sun's colour at a height, its luminance one: Rayleigh transmittance
	-- through an air mass of 1 / sin(elevation), the optical depths sea
	-- level's at 680, 550 and 440 nm ([PBR_FIT] term 3)
	function PHYS.sun_rgb(height)
		local m = 1 / math.max(height, 0.05)
		local r, g, b = math.exp(-0.05 * m), math.exp(-0.10 * m),
				math.exp(-0.24 * m)
		local lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
		return r / lum, g / lum, b / lum
	end

	-- The flash's radiance; see M.FLASH below
	function M.flash_radiance()
		return M.FLASH * PHYS.sky_zenith
	end

	-- The sky's two ends at a sun height: a hue -- PHYS.day_zenith and
	-- day_horizon, the render's, unless a caller has its own -- at the
	-- reference's radiance ([PBR_FIT] term 1)
	function M.sky_radiance(zenith, horizon, height)
		local function at(c, radiance)
			local l = lum(c)
			if l <= 1e-6 then
				return {r = radiance, g = radiance, b = radiance}
			end
			local k = radiance / l
			return {r = c.r * k, g = c.g * k, b = c.b * k}
		end
		return at(zenith, PHYS.night_sky +
				(PHYS.sky_zenith - PHYS.night_sky) * PHYS.sky(height)),
			at(horizon, PHYS.night_sky +
				(PHYS.sky_horizon - PHYS.night_sky) * PHYS.horizon(height))
	end

	-- The sun's disc at a radiance: E0 of the hour over the disc's solid
	-- angle, pi times the half-width squared (the tangent of the half-angle,
	-- near enough), in its colour. The path trace's disc is this and clips
	-- white at every hour; Luanti's square at texture brightness sat under
	-- the snow after metering ([PBR_FIT] step 2). rgba16f holds 65 504.
	function M.sun_disc(height, half, color)
		local disc = math.min(PHYS.sun(height) / (math.pi * half * half), 65504)
		return disc * color.r, disc * color.g, disc * color.b
	end

	-- The clouds' light ([CLOUD_LIGHT]): a reflectance (the cloud colour, a
	-- cloud top's near 0.9) lit by the sun and the sky, not a display colour
	-- in a radiance sky. Returns the sun's and the sky's for the dome's
	-- set_cloud_lit. The sky's share is the dome's mean as it is ([DUSK_CLOUD]:
	-- a dome of radiance L puts pi L on a face, which reflects albedo L); the
	-- sun's is E_sun of the hour times how high it is, times k_sun, set so
	-- that at noon a thin cloud is cloud_n times the zenith patch (PHYS.cloud_n,
	-- rated by the user). sun_through: what of the sun gets through
	-- (the Luanti weather's direct_light()).
	function M.cloud_lit(albedo, zenith, horizon, height, sun_through, cloud_n)
		local mean = M.dome(zenith, horizon)
		local n = cloud_n or PHYS.cloud_n
		local noon_mean = (5 * PHYS.sky_zenith + PHYS.sky_horizon) / 6
		local k_sun = math.max(0, (n * PHYS.sky_zenith / M.CLOUD_REF_LUM -
				noon_mean) * math.pi / PHYS.sun(1))
		-- The sun as the clouds see it: from 7 km up it sets PHYS.cloud_dip
		-- later, through the longer air that reddens it
		local h = height + PHYS.cloud_dip
		local e = PHYS.sun(h) * math.max(h, 0) * k_sun / math.pi * sun_through
		local sr, sg, sb = PHYS.sun_rgb(h)
		-- And the dusk glow is sky light too: what a cloud gets of it is the
		-- dome's mean of PhysicalSky's glow term, (1 - y)^2 over the hemisphere
		-- (a third) times away + (1 - away) of a quarter for cos^2 towards the sun
		local gm = M.dawn_glow(height) * M.DUSK_SKY *
				(M.DUSK_AWAY + (1 - M.DUSK_AWAY) / 4) / 3
		local gc = M.DAWN_COLOR
		return {r = albedo.r * e * sr, g = albedo.g * e * sg, b = albedo.b * e * sb},
			{r = albedo.r * (mean.r + gm * gc.r), g = albedo.g * (mean.g + gm * gc.g),
				b = albedo.b * (mean.b + gm * gc.b)}
	end
	M.PHYS = PHYS
	return M
end
bind(PHYS, M)
do
	local hr, _, hb = PHYS.sun_rgb(1)
	local lr, _, lb = PHYS.sun_rgb(0)
	assert(hb / hr > 0.75 and lb / lr < 0.05,
			"white overhead, red on the horizon")
end

-- What a full overcast takes from the zenith where the game's own day
-- colours are not drawn (pbr draws the reference's), a named pick
M.OVERCAST_DIM = 0.6

-- **The sky under cover**: an overcast sky is darker at the horizon than
-- overhead -- the standard overcast sky's luminance goes as (1 + 2 sin h)
-- / 3, a third of the zenith's at the horizon -- and is the clouds'
-- colour. By the cover c, the zenith goes to the clouds' hue at its own
-- brightness (less zenith_dim of it: OVERCAST_DIM where the game's own
-- darker colours are not drawn, 0 where they are) and the horizon, and
-- with it the fog, to the same hue at a third of that. c = 0 changes
-- nothing. Works in any linear units: display colours or radiance.
-- -> zenith, horizon
function M.overcast(zenith, horizon, cloud, cover, zenith_dim)
	if not cover or cover <= 0 then
		return zenith, horizon
	end
	cloud = cloud or {r = 1, g = 1, b = 1}
	local cl = lum(cloud)
	local hue = cl > 1e-6 and {r = cloud.r / cl, g = cloud.g / cl,
			b = cloud.b / cl} or {r = 1, g = 1, b = 1}
	local top = lum(zenith) * (1 - (zenith_dim or 0) * cover)
	local function mix(a, k, l)
		return {r = a.r + (hue.r * l - a.r) * k, g = a.g + (hue.g * l - a.g) * k,
				b = a.b + (hue.b * l - a.b) * k}
	end
	return mix(zenith, cover, top), mix(horizon, cover, top / 3)
end

-- **The meter under cover** (pbr): a metered camera puts an overcast day
-- at the clear day's brightness, which reads as no weather at all; the eye
-- sees a storm as dark. The meter's middle grey, less this share of it
-- under full cover -- a named pick.
-- The cloud albedo pbr's k_sun is rated at (Luanti's default cloud
-- colour, 0.9 0.92 0.95): a game's darker colour is then a darker cloud
-- rather than one k_sun lights back up to the same white -- VoxeLibre's
-- rain colour, its sun left visible on a Luanti server
M.CLOUD_REF_LUM = 0.917
M.OVERCAST_EXPOSURE = 0.5
function M.middle_grey(grey, cover)
	return grey * (1 - M.OVERCAST_EXPOSURE * (cover or 0))
end

-- **The flash**: a lightning bolt -- a particle at full glow, Luanti's
-- "draw me as a light" -- and the game's sky gone white for a moment
-- (VoxeLibre's lightning layer, 0.1 s). On pbr both are this many times
-- the noon zenith's radiance, above anything the sky is, so they show over
-- the exposure as a flash; the other modes draw them at white.
M.GLOW_FULL = 14
M.FLASH = 3

do
	local function rgb(hex)
		return {r = tonumber(hex:sub(1, 2), 16) / 255,
				g = tonumber(hex:sub(3, 4), 16) / 255,
				b = tonumber(hex:sub(5, 6), 16) / 255}
	end
	local z, h = {r = 0.4, g = 0.6, b = 1.0}, {r = 0.6, g = 0.7, b = 0.9}
	local z2, h2 = M.overcast(z, h, rgb("F0F0FF"), 0)
	assert(z2 == z and h2 == h, "no cover changes nothing")
	-- Under a thunderstorm: grey, the horizon a third of the zenith
	local zt, ht = M.overcast(z, h, rgb("3D3D3F"), 1, 0)
	assert(math.abs(lum(ht) - lum(zt) / 3) < 1e-6, "the horizon a third")
	assert(math.abs(zt.r - zt.b) < 0.05 * lum(zt), "the clouds' grey")
	local zd = M.overcast(z, h, rgb("5D5D5F"), 1, M.OVERCAST_DIM)
	assert(lum(zd) < lum(z) * 0.5, "pbr's zenith darkens under cover")
	assert(M.flash_radiance() > PHYS.sky_zenith, "over the noon sky")
end

-- How far past white the sun's disc is drawn, which is what makes it read as
-- a light rather than a white circle. The extension's own value.
local SUN_OVEREXPOSURE = 2.5

-- **The dawn glow** ([DAWN_LIGHT], the term the user set the two ramps
-- aside for, 2026-09-25): the light of the sky before the sun, as a
-- radiance of its own on [DUSK_SKY]'s ramp below -- in the sky's
-- units (noon's dome is about 5.4). It does not raise the sun or the sky
-- curve: the sky's band is brightened by it as a radiance, and the
-- ambient, the bounce and the ground light take a share of it, in the
-- glow's orange. Dusk is the mirror, the sun's height being the same.
-- The band's radiance at its peak and the share of it the ambient terms
-- take are the user's pick off local/options_for_DAWN_LIGHT/glow/,
-- g1.0_a0.3 (2026-10-03).
M.DAWN_GLOW = 1.0
M.DAWN_AMBIENT = 0.3
M.DAWN_COLOR = {r = 1.0, g = 0.55, b = 0.25}
-- [DUSK_SKY], pbr only: the band round the low sun is this many times the
-- sky's own level, in the glow's orange (a fixed white before, which was
-- a white patch on a black sky after sunset), and the glow reaches the
-- dome away from the sun at this share of what it is towards it.
M.DUSK_BAND = 2.0
M.DUSK_AWAY = 0.3
-- [DUSK_CLOUD]: the share of the glow and the band the sky itself shows
-- (the ambient keeps all of it); the clouds get the glow as sky light at
-- the dome's mean (the user kept gain 1 off local/options_for_DUSK_CLOUD/).
M.DUSK_SKY = 0.7

-- **The dusk as one ramp** ([DUSK_SKY], the user's anchors, 2026-10-04):
-- blue sky with the sun -> bright orange -> orange -> dark orange -> dark.
-- 18:40 as it was, the orange up from there, at its peak at 19:30, and the
-- starry night fully uncovered at 20:20; the dawn the same mirrored about
-- noon (03:40, 04:30, 05:20), which is the same sun heights. The glow was
-- at its most just under the horizon and nothing just over it: a step at
-- 19:00, and the band's tint turned orange within those same minutes.
-- simplified: the heights are the untilted orbit's at those hours; a game
-- that tilts it moves the hours a little.
M.DUSK_FROM = 0.079   -- 18:40, 05:20
M.DUSK_PEAK = -0.151  -- 19:30, 04:30
-- The stretch from the peak to dark halved (user, 2026-10-06): the meter
-- holds it at one brightness, so it read as a flat orange hour. The
-- predawn light keeps its own -0.403.
M.DUSK_TO = -0.279  -- 19:55, 04:05
-- Each part of it crossed eased (smoothstep); linear was the options
-- round's other, and the meter hides the difference (e24fb6e6)
local function dusk_shape(u)
	u = clamp01(u)
	return u * u * (3 - 2 * u)
end

-- The share of orange in the band round the sun: none at 18:40, all of it
-- from 19:30 on (PhysicalSky's cDuskBand.z)
function M.dusk_tint(height)
	return dusk_shape((M.DUSK_FROM - height) / (M.DUSK_FROM - M.DUSK_PEAK))
end

-- The glow's radiance at a sun's height: up from 18:40, the most at 19:30,
-- gone at 19:55
function M.dawn_glow(height)
	if height >= M.DUSK_FROM or height <= M.DUSK_TO then
		return 0
	elseif height >= M.DUSK_PEAK then
		return M.DAWN_GLOW * M.dusk_tint(height)
	end
	return M.DAWN_GLOW * dusk_shape((height - M.DUSK_TO) /
			(M.DUSK_PEAK - M.DUSK_TO))
end
assert(M.dawn_glow(0.1) == 0 and M.dawn_glow(-0.45) == 0,
		"no glow before 18:40 or after 19:55")
assert(math.abs(M.dawn_glow(M.DUSK_PEAK) - M.DAWN_GLOW) < 0.001,
		"the most at 19:30")
assert(math.abs(M.dawn_glow(-0.001) - M.dawn_glow(0.001)) < 0.02 * M.DAWN_GLOW,
		"no step where the sun crosses the horizon")
assert(M.dusk_tint(0.2) == 0 and M.dusk_tint(-0.3) == 1, "the tint's ends")

-- The dome's hue for the ambient: the cosine weighting a face sees. Five
-- parts zenith, one horizon: with the horizon white a third of it made
-- every shade too warm -- the render's open shaded wall reads B/R 0.92 and
-- pbr's read 0.68 ([PBR_FIT], open_shade_dirt) -- the band being bright
-- but narrow under the cosine
function M.dome(zenith, horizon)
	return {r = (5 * zenith.r + horizon.r) / 6,
		g = (5 * zenith.g + horizon.g) / 6,
		b = (5 * zenith.b + horizon.b) / 6}
end

-- How much the sky is drawn, by how much of it the camera sees
-- (voxel_shading.sky_visibility_above()): a late and conservative gate
-- rather than a fade -- anything less than fully enclosed draws the sky
-- as it is, and only a cave with essentially no sky over it dims it. The
-- short ramp is so that walking into one is not a step ([CAVE_SKY]).
function M.outside(seen)
	return math.max(0, math.min(1, (seen - 0.02) / 0.08))
end

-- The fog: the drawn horizon's radiance where the sky is seen, the
-- ambient where it is not -- a display colour dimmed by the hour sat at
-- 0.004 under a night sky of 0.00005 and the meter lifted the far edge of
-- the range to white ([LOD_LIGHT]); a cave's haze is the light a cave
-- gets
function M.fog(horizon, ambient, seen)
	local k = 1 - seen
	return {r = horizon.r + (ambient.r - horizon.r) * k,
		g = horizon.g + (ambient.g - horizon.g) * k,
		b = horizon.b + (ambient.b - horizon.b) * k}
end

assert(M.outside(0) == 0 and M.outside(1) == 1, "the gate's ends")


-- **Where the sun is by place and time** (floorplanner's, [FP_DAYLIGHT];
-- here for every app that has a latitude, [HILLCLIMB]): the direction
-- towards the sun in a scene whose +X is the plan view's right, +Z up the
-- screen and +Y up, and the sine of its elevation. `north` is
-- degrees clockwise from the plan view's up to north; `day` 1..365,
-- `minute` 0..1439 of solar time.
-- simplified: solar time (no equation of time, a quarter of an hour at
-- most; no longitude or time zone), and the declination's cosine fit
function M.sun_toward(lat, north, day, minute)
	local rad, sin, cos = math.rad, math.sin, math.cos
	local decl = rad(-23.44 * cos(rad(360 / 365 * (day + 10))))
	local hour_angle = rad((minute / 60 - 12) * 15)
	local p = rad(lat)
	local sin_h = sin(p) * sin(decl) + cos(p) * cos(decl) * cos(hour_angle)
	sin_h = math.max(-1, math.min(1, sin_h))
	local cos_h = math.sqrt(1 - sin_h * sin_h)
	-- The azimuth from south, westward; then from north, eastward
	local az = math.atan2(sin(hour_angle), cos(hour_angle) * sin(p) -
			math.tan(decl) * cos(p)) + math.pi
	local east, northward = sin(az) * cos_h, cos(az) * cos_h
	local a = rad(north)
	local nx, nz = sin(a), cos(a)
	local ex, ez = cos(a), -sin(a)
	return east * ex + northward * nx, sin_h, east * ez + northward * nz
end

-- **The sky's turn** ([STARS_AXIS]): turn_rows(axis, angle) is the
-- inverse of the turn by angle (radians) about axis (a unit vector),
-- row by row, nine numbers: what set_sky_turn gives the shader, which
-- looks a star up at it applied to the view's direction. With the sky's
-- turn, the stars stay where the sun and the moon put them.
function M.turn_rows(k, a)
	local c, s = math.cos(a), math.sin(a)
	local t = 1 - c
	local x, y, z = k.x, k.y, k.z
	return {c + t * x * x, t * x * y + s * z, t * x * z - s * y,
		t * y * x - s * z, c + t * y * y, t * y * z + s * x,
		t * z * x + s * y, t * z * y - s * x, c + t * z * z}
end
-- An orbit tilted about X by `tilt` degrees, as Luanti's and
-- sky_model.sun_direction tilt theirs: the axis Z turned by the tilt
function M.tilted_axis(tilt)
	local r = math.rad(tilt or 0)
	return {x = 0, y = -math.sin(r), z = math.cos(r)}
end
-- sun_toward's sky: the axis the celestial pole (north raised by the
-- latitude) and the angle by the hour, for a minute of solar time
function M.sky_turn_toward(lat, north, minute)
	local a, p = math.rad(north), math.rad(lat)
	local axis = {x = math.sin(a) * math.cos(p), y = math.sin(p),
		z = math.cos(a) * math.cos(p)}
	return axis, math.rad((minute / 60 - 12) * 15)
end

do
	local function apply(r, v)
		return r[1] * v[1] + r[2] * v[2] + r[3] * v[3],
			r[4] * v[1] + r[5] * v[2] + r[6] * v[3],
			r[7] * v[1] + r[8] * v[2] + r[9] * v[3]
	end
	-- One point, in degrees off the first, over a day of turned-back suns
	local function spread(sun_at, turn_at)
		local fx, fy, fz, worst
		for i = 0, 47 do
			local v = {sun_at(i)}
			local x, y, z = apply(M.turn_rows(turn_at(i)), v)
			if not fx then
				fx, fy, fz, worst = x, y, z, 0
			else
				local d = math.max(-1, math.min(1, fx * x + fy * y + fz * z))
				worst = math.max(worst, math.deg(math.acos(d)))
			end
		end
		return worst
	end
	-- A tilted orbit (22.8, the luanti client's own): the sun at
	-- (cos a, sin a, 0) turned by the tilt about X
	local tilt = 22.8
	local r = math.rad(tilt)
	local w = spread(function(i)
		local a = i / 48 * 2 * math.pi
		local x, y = math.cos(a), math.sin(a)
		return x, y * math.cos(r), y * math.sin(r)
	end, function(i)
		return M.tilted_axis(tilt), i / 48 * 2 * math.pi
	end)
	assert(w < 0.5, "the tilted sun turned back moves " .. w .. " degrees")
	-- sun_toward's, at 60 north on midsummer, north a quarter turned
	w = spread(function(i)
		local x, y, z = M.sun_toward(60, 90, 172, i * 30)
		local l = math.sqrt(x * x + y * y + z * z)
		return x / l, y / l, z / l
	end, function(i)
		return M.sky_turn_toward(60, 90, i * 30)
	end)
	assert(w < 0.5, "sun_toward's sun turned back moves " .. w .. " degrees")
	-- No tilt: the shader's old turn, about Z by the sun's own angle
	local rows = M.turn_rows({x = 0, y = 0, z = 1}, 0.7)
	assert(math.abs(rows[1] - math.cos(0.7)) < 1e-9 and
			math.abs(rows[2] - math.sin(0.7)) < 1e-9 and
			math.abs(rows[4] + math.sin(0.7)) < 1e-9, "the untilted turn")
end

-- **physical_sky with an app's own numbers**: a copy of the module whose
-- PHYS has these values in place of the defaults (floorplanner's night and
-- lamp), every rule here reading them. The module's table, which require
-- shares between a client's callers, is not changed.
-- simplified: one level; with() on the copy starts from the defaults again.
function M.with(overrides)
	local W, P = {}, {}
	for k, v in pairs(M) do
		W[k] = v
	end
	for k, v in pairs(PHYS) do
		if type(v) ~= "function" then
			P[k] = v
		end
	end
	for k, v in pairs(overrides) do
		P[k] = v
	end
	W.safe = W
	return bind(P, W)
end
do
	local W = M.with({sun_e0 = 2 * PHYS.sun_e0, night_sky = 1})
	assert(W.PHYS.sun(1) == 2 * PHYS.sun(1) and M.PHYS == PHYS,
			"with(): the copy's rules read its own numbers")
	assert(W.sky_radiance({r = 1, g = 1, b = 1}, {r = 1, g = 1, b = 1},
			-1).r > 0.9, "with(): the night sky")
end

-- **The dome**: a skybox drawn by PhysicalSky.glsl.
--
-- **Every uniform is set here at creation**, including the ones nothing ever
-- changes: a shader parameter a material never sets reads as zero, and zero
-- for most of these is a black sky.
--
-- defaults: what the sky is before anyone says -- zenith, horizon,
-- sun_color, sun_half, cloud_cover, cloud_light (builtin/voxel_shading's
-- sky_defaults has them) and moon_half, cloud_alpha and cloud_wind ({x, z},
-- the shader's units a second; nil is still), which a Luanti client takes
-- from Luanti's own. log: the game's logger.
function M.new_dome(scene, sun_dir, defaults, log)
	local node = scene:CreateChild("SkyDome")
	local box = node:CreateComponent("Skybox")
	box:SetModel(magic.cache:GetResource("Model", "Models/Box.mdl"))
	local material = magic.Material:new()
	material:SetTechnique(0, magic.cache:GetResource("Technique",
			"physical_sky/PhysicalSky.xml"))
	-- PhysicalSky.xml says cull="none" itself, unlike Urho3D's own skybox
	-- technique; a box seen from the inside is entirely back-facing, and a
	-- material that does not say so draws nothing at all.
	box.material = material

	local self = {node = node, material = material}
	local wind_default = defaults.cloud_wind or {0, 0}

	-- Each parameter set only when it changes: a client tells the sky
	-- everything every frame, and a set and its vector are sandbox calls
	-- ([FRAME_WORK]). One, two or three numbers, a float or a vector.
	local last = {}
	local function set(name, x, y, z)
		local l = last[name]
		if l and l[1] == x and l[2] == y and l[3] == z then
			return
		end
		if l then
			l[1], l[2], l[3] = x, y, z
		else
			last[name] = {x, y, z}
		end
		if z ~= nil then
			material:SetShaderParameter(name, magic.Vector3(x, y, z))
		elseif y ~= nil then
			material:SetShaderParameter(name, magic.Vector2(x, y))
		else
			material:SetShaderParameter(name, x)
		end
	end
	-- For a caller with parameters of its own on the same material (the
	-- Luanti sky's, builtin/luanti's sky_dome.lua)
	self.set_param = set
	-- And the two bodies' pictures, by the same rule
	local sun_texture_now, moon_texture_now = nil, nil

	-- Everything, at what the sky looked like before any game said anything
	set("SunDirection", -sun_dir.x, -sun_dir.y, -sun_dir.z)
	set("SkyTop", defaults.zenith.r, defaults.zenith.g, defaults.zenith.b)
	set("SkyHorizon", defaults.horizon.r, defaults.horizon.g, defaults.horizon.b)
	set("SunTint", defaults.sun_color.r, defaults.sun_color.g,
			defaults.sun_color.b)
	set("SunSize", defaults.sun_half)
	set("SunOverexposure", SUN_OVEREXPOSURE)
	-- The moon is a body of its own here, drawn opposite the sun
	set("MoonSize", defaults.moon_half or 0)
	set("MoonTextured", 0.0)
	set("SunTextured", 0.0)
	set("StarDensity", 0.0)
	set("SkyTurnOn", 0.0)
	set("SkyTurnX", 1, 0, 0)
	set("SkyTurnY", 0, 1, 0)
	set("SkyTurnZ", 0, 0, 1)
	set("StarColor", 0.9, 0.9, 1.0)
	set("StarFade", 0.0)
	set("CloudCoverage", defaults.cloud_cover)
	set("CloudAlpha", defaults.cloud_alpha or 1)
	set("CloudWind", wind_default[1], wind_default[2])
	-- What a player who cannot see the sky is under, and whether the game
	-- allows the dimming at all. Luanti's own indoors default is #646464
	-- and auto_dim_skybox is on; see set_indoors() below and [CAVE_SKY].
	set("SkyIndoors", 0.39, 0.39, 0.39)
	set("SkyAutoDim", 1.0)
	set("SkyOvercast", 0.0)

	-- The gradient's two ends, and how much of the sky is cloud. Anything
	-- nil is left as it is, which is what the old sky did too.
	function self:set_look(zenith, horizon, cloud_cover)
		if zenith then
			set("SkyTop", zenith.r, zenith.g, zenith.b)
		end
		if horizon then
			set("SkyHorizon", horizon.r, horizon.g, horizon.b)
		end
		if cloud_cover then
			set("CloudCoverage", math.max(0, math.min(1, cloud_cover)))
		end
	end

	-- The pbr path's cloud: lit rather than coloured ([CLOUD_LIGHT]);
	-- the two vectors the shader adds, computed by the caller from the
	-- sun and the sky of the hour
	function self:set_cloud_lit(sun, sky)
		set("CloudSun", sun.r, sun.g, sun.b)
		set("CloudSky", sky.r, sky.g, sky.b)
	end


	-- Half the width of the square, and what colour it is. Zero turns it
	-- off, which is how a game says its sun or its moon is not there.
	-- How opaque the clouds are (0..1) and how fast they drift, {x, z} in
	-- the shader's units a second; nil leaves the defaults
	function self:set_clouds(alpha, wind)
		set("CloudAlpha", alpha or defaults.cloud_alpha or 1)
		wind = wind or wind_default
		set("CloudWind", wind[1], wind[2])
	end

	-- An overcast dome (floorplanner's [FP_OVERCAST]): the gradient spread
	-- up by the square root rather than the clear sky's; see cSkyOvercast
	function self:set_overcast(on)
		set("SkyOvercast", on and 1.0 or 0.0)
	end

	function self:set_sun_look(half, color)
		set("SunSize", math.max(0, half or 0))
		if color then
			set("SunTint", color.r or color[1] or 1, color.g or color[2] or 1,
					color.b or color[3] or 1)
		end
	end

	-- [DAWN_LIGHT]'s glow on the band along the horizon, a radiance
	-- and tint, the band's share of orange (M.dusk_tint())
	function self:set_dawn_glow(r, g, b, tint)
		set("DawnGlow", r, g, b)
		set("DuskBand", M.DUSK_BAND * M.DUSK_SKY, M.DUSK_AWAY, tint or 0)
	end

	-- The game's own picture of it, or nil for the shader's painted square.
	-- PhysicalSky reads the sun's from sDiffMap and the moon's from
	-- sNormalMap -- two units because a material has no third one this
	-- needs.
	-- The disc at a radiance, for the pbr path; zero is Luanti's square
	function self:set_sun_radiance(r, g, b)
		set("SunRadiance", r, g, b)
	end

	function self:set_sun_texture(texture)
		if texture and texture ~= sun_texture_now then
			sun_texture_now = texture
			material:SetTexture(magic.TU_DIFFUSE, texture)
		end
		set("SunTextured", texture and 1.0 or 0.0)
	end

	-- The moon is drawn opposite the sun, which is where Luanti puts it, so
	-- it needs no direction of its own: half its width is the whole of what
	-- says it is there. Its colour is the shader's, a moon having no tint to
	-- take from the horizon.
	function self:set_moon_look(half)
		set("MoonSize", math.max(0, half or 0))
	end

	function self:set_moon_texture(texture)
		if texture and texture ~= moon_texture_now then
			moon_texture_now = texture
			material:SetTexture(magic.TU_NORMAL, texture)
		end
		set("MoonTextured", texture and 1.0 or 0.0)
	end

	-- **Where the two skies disagree.** builtin/voxel_shading folds how many
	-- stars there are and how visible they are into one density, and takes a
	-- size; PhysicalSky keeps the two apart and has no size. So the count
	-- goes to the density and the night ramp goes to the fade, which is the
	-- better shape: stars come out rather than appearing one by one.
	function self:set_star_look(density, color, fade)
		set("StarDensity", math.max(0, density or 0))
		set("StarFade", math.max(0, math.min(1, fade or 1)))
		if color then
			set("StarColor", color.r or color[1] or 0.9, color.g or color[2] or 0.9,
					color.b or color[3] or 1.0)
		end
	end

	-- [STARS_AXIS] The axis ({x, y, z}, a unit vector) the sun, the moon
	-- and the stars go round, and the turn's angle (radians) about it: the
	-- stars are drawn turned by it. nil: Luanti's untilted turn, read off
	-- the sun's direction
	function self:set_sky_turn(axis, angle)
		if not axis then
			set("SkyTurnOn", 0.0)
			return
		end
		local r = M.turn_rows(axis, angle)
		set("SkyTurnX", r[1], r[2], r[3])
		set("SkyTurnY", r[4], r[5], r[6])
		set("SkyTurnZ", r[7], r[8], r[9])
		set("SkyTurnOn", 1.0)
	end

	-- The way the light travels, as a Light's direction is, so the sun
	-- itself is the other way -- which is what the old sky took too.
	function self:set_sun_direction(dir)
		if dir then
			set("SunDirection", -dir.x, -dir.y, -dir.z)
		end
	end

	-- The colour a direction that cannot see the sky is drawn as, already
	-- multiplied by how light it is, and whether the game lets this happen.
	-- What the mix is by is the sky visibility cube, per direction, which
	-- the client keeps for the reflections already -- so a cave goes dark
	-- and a tunnel mouth does not, without anything having to work out
	-- which is which. See [CAVE_SKY] in doc/plan/rendering_plan.md.
	function self:set_indoors(color, brightness)
		if color == nil then
			return
		end
		local k = math.max(0, brightness or 1)
		set("SkyIndoors", (color.r or 0.39) * k, (color.g or 0.39) * k,
				(color.b or 0.39) * k)
	end

	function self:set_auto_dim(on)
		set("SkyAutoDim", on and 1.0 or 0.0)
	end

	-- How much sky the camera can see, as one number rather than a
	-- direction: 0 in a cave and 1 anywhere that is not one. **The sky is
	-- edited only once there is no sky to see**, which is the rule the halos
	-- cost -- mixing per direction darkened the real sky in a blob around
	-- every occluder, the visibility cube being camera-local and thirty
	-- degrees to a cell while the sky is at infinity. See [CAVE_SKY].
	function self:set_outside(k)
		set("SkyOutside", math.max(0, math.min(1, k or 1)))
	end

	function self:enabled(on)
		node.enabled = on and true or false
	end

	log:info("the sky is physical_sky's dome")
	return self
end


-- 64 a side: a reflection is mip-blurred by roughness and a mirror of the
-- sky at this size is a sky
local SIZE = 64

-- Where each of Urho3D's six faces looks: the same directions, set the
-- same way (the node's direction, world up), that View.cpp gives a point
-- light's shadow cameras, so the faces land where the cube-map sampler
-- expects them
local FACES = {
	{face = "FACE_POSITIVE_X", dir = {1, 0, 0}},
	{face = "FACE_NEGATIVE_X", dir = {-1, 0, 0}},
	{face = "FACE_POSITIVE_Y", dir = {0, 1, 0}},
	{face = "FACE_NEGATIVE_Y", dir = {0, -1, 0}},
	{face = "FACE_POSITIVE_Z", dir = {0, 0, 1}},
	{face = "FACE_NEGATIVE_Z", dir = {0, 0, -1}},
}

local Cube = {}

-- **The cube** ([SKY_REFLECTIONS], extensions/skycube before
-- [LC_SKY_SHARED]): the sky rendered into a small cube for the world to
-- reflect -- sun, moon and dawn where they are.
--
--   local cube = physical_sky.new_cube(dome.material)
--   zone.zoneTexture = cube.texture
--   cube:update()   -- when the sky has moved enough to show
--   cube:tick()     -- every frame
--
-- The cube is a scene of its own holding one Skybox that shares the sky's
-- material, so whatever the client sets on the material -- the hour's
-- colours, the sun's direction, the moon -- is what the cube draws, and
-- six viewports on the cube's faces with one camera each at the origin.
-- The faces are drawn only when update() asks: a reflection nobody
-- watches change is not worth six renders a frame.
function M.new_cube(material)
	-- The methods copied in: the sandbox has no setmetatable
	local self = {}
	for k, v in pairs(Cube) do
		self[k] = v
	end
	self.scene = magic.Scene()
	self.scene:CreateComponent("Octree")
	local node = self.scene:CreateChild("Sky")
	local box = node:CreateComponent("Skybox")
	box:SetModel(magic.cache:GetResource("Model", "Models/Box.mdl"))
	box.material = material

	-- Half floats: the sky is drawn in HDR at the reference's radiances
	-- (several times white, see [PBR_FIT]) and eight bits would clip it
	self.texture = magic.TextureCube:new()
	if not self.texture:SetSize(SIZE, magic.Graphics.GetRGBAFloat16Format(),
			magic.TEXTURE_RENDERTARGET) then
		error("physical_sky: could not make a " .. SIZE .. " render target cube")
	end
	-- The texture held by the engine, not only by whoever draws with it:
	-- a Lua handle does not count in Urho3D's reference count, and when
	-- a game with its own six-picture skybox took the cube off the
	-- world's zone, the cube was freed under these surfaces and the next
	-- update() wrote into freed memory (nodecore, 2026-09-21: the client
	-- died ten seconds in). A Zone of the cube's own scene holds it; the
	-- scene is held by the faces' viewports.
	local hold = node:CreateComponent("Zone")
	hold.zoneTexture = self.texture
	hold.priority = -1000
	self.surfaces = {}
	for i, f in ipairs(FACES) do
		local cam_node = self.scene:CreateChild("Face" .. i)
		cam_node.direction = magic.Vector3(f.dir[1], f.dir[2], f.dir[3])
		local camera = cam_node:CreateComponent("Camera")
		camera.fov = 90
		camera.nearClip = 0.1
		camera.farClip = 100
		local surface = self.texture:GetRenderSurface(magic[f.face])
		surface:SetViewport(0, magic.Viewport:new(self.scene, camera))
		surface.updateMode = magic.SURFACE_MANUALUPDATE
		self.surfaces[i] = surface
	end
	self:update()
	return self
end

-- Draw the six faces again, on the next frame
-- **One face a frame, not six in one** ([CLIENT_FRAME], 2026-09-26).
-- Six faces queued together are six scene renders in the same frame, and
-- on a client whose frame is already the GPU's that shows as a bump once
-- a second: a settled VoxeLibre world peaked at 0.055 to 0.073 s with
-- them together and 0.049 to 0.057 with the cube left alone. The sky
-- moves slowly enough that a face which is five frames behind the others
-- cannot be told apart -- what a player would see is the bump.
--
-- `update()` asks for a refresh; the faces go out one a frame from
-- `tick()`, which the game calls every frame.
function Cube:update()
	self.due = #self.surfaces
end

function Cube:tick()
	if (self.due or 0) <= 0 then
		return
	end
	local i = #self.surfaces - self.due + 1
	self.due = self.due - 1
	local surface = self.surfaces[i]
	if surface then
		surface:QueueUpdate()
	end
end

-- Everything at once, for the first build of the cube: a world whose
-- reflections are a sixth of a sky for the first frames looks wrong in a
-- way a moving sky does not
function Cube:update_now()
	self.due = 0
	for _, surface in ipairs(self.surfaces) do
		surface:QueueUpdate()
	end
end


return M
-- vim: set noet ts=4 sw=4:
