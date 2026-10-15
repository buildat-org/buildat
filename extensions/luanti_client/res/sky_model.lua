-- SPDX-License-Identifier: Apache-2.0 OR MIT
-- **The sky's model, one copy for both Luanti clients** ([LUANTI_SHARED]):
-- when the sun and the moon are up, where the sun is, when its light goes
-- red, and the light before dawn. In Luanti's own units of the day,
-- 0...24000. The extension's world.lua and apps/vanilla's sky_dome.lua
-- each draw a sky from it; the module's client gets it as
-- luanti/sky_model.lua (serve_shared_lua).
local M = {}

-- Half the width of the moon's square at a game scale of one, on a plane one
-- unit along its direction: Luanti's own ratio to the sun's 0.075.
M.MOON_HALF = 0.048

-- How many stars a game asks for when it says nothing, and how many of the
-- star grid's cells hold one at that count. **The grid is SkyDome.glsl's
-- own**, two faces of STAR_GRID squared cells, which is about a quarter of a
-- million -- so a thousand stars is four thousandths of them, and a game
-- asking for more gets more in proportion.
M.STARS_DEFAULT = 1000
M.STAR_DENSITY_DEFAULT = 0.004

-- What the sun and the moon go as they cross the horizon, when the game has
-- not said: Luanti's own default fog_sun_tint #f47d1d and fog_moon_tint
-- #7f99cc. Not the horizon of this hour, which is a washed-out blue and
-- lights a sunset grey. A game's own arrive as game_sky.sun_tint and
-- moon_tint now -- see [SKY_KNOBS] -- and these are the fallback.
M.SUN_TINT = {r = 244 / 255, g = 125 / 255, b = 29 / 255}
M.MOON_TINT = {r = 127 / 255, g = 153 / 255, b = 204 / 255}

-- **The schedule** (see [LIGHT_SHAPE] in doc/plan/rendering_plan.md: the
-- extension's shape, which vanilla took whole). Everything below is in Luanti's own units of the day,
-- 0...24000, so it is a fixed hour however fast a game's clock runs.
--
-- Why a fade and not a switch: a directional light below the horizon shines
-- up through the world, and its specular is then the brightest thing in a
-- night frame, lit from the wrong side of the sky. So the sun is taken out
-- of the scene for the night and the moon is put in, each fading over the
-- hour on either side of the sun being level with the horizon.
local SUN_RISE = 5000     -- nothing before this
local SUN_UP = 6000       -- full sun from here
local SUN_SET = 18000     -- full sun until here
local SUN_DOWN = 19000    -- nothing after this

-- The moon's day is a little longer than the sun's night: it is going
-- before the sun arrives and does not come back until the sun is well gone.
local MOON_FADE_OUT = 4500
local MOON_OUT = 5500
local MOON_FADE_IN = 18500
local MOON_IN = 19500

-- Nothing above the horizon shines from under it. The clocks are where the
-- fade is shaped; this is the line itself, taken from where the body
-- actually is. A couple of degrees of softness, because a light that
-- switches off in one frame is a light that pops.
local HORIZON_FADE = 0.05

-- Where the sun is for the purpose of casting a shadow, which is not quite
-- where it is: a shadow map rasterized afresh every frame from a light that
-- has turned a little between two of them has crawling edges. Holding the
-- direction still for a step at a time trades the crawl for a small jump.
-- A hundred of these is a degree and a half.
local SUN_STEP = 100

-- The half hour either side of the sun crossing the horizon, which is the
-- window dawn and dusk happen in.
local RED_HALF_WIDTH = 500
-- How much of that red the light takes. Not all of it: the tint is the
-- colour a band of sky is painted, which is deeper than the light painting
-- it.
local SUN_TINT_SHARE = 0.9

local function clamp01(v)
	return v < 0 and 0 or (v > 1 and 1 or v)
end

-- 0 before the rise, 1 between the rise and the set, 0 after it, and the way
-- across each ramp in between
local function up_between(t, rise_from, rise_to, set_from, set_to)
	t = (t or 12000) % 24000
	if t <= rise_from or t >= set_to then
		return 0
	elseif t < rise_to then
		return (t - rise_from) / (rise_to - rise_from)
	elseif t <= set_from then
		return 1
	end
	return (set_to - t) / (set_to - set_from)
end

function M.sun_amount(t)
	return up_between(t, SUN_RISE, SUN_UP, SUN_SET, SUN_DOWN)
end

-- The same shape read the other way round, so the four numbers above say
-- when the moon is out rather than being the sun's turned inside out
function M.moon_amount(t)
	return 1 - up_between(t, MOON_FADE_OUT, MOON_OUT, MOON_FADE_IN, MOON_IN)
end

function M.above_horizon(sine_of_elevation)
	return clamp01((sine_of_elevation or 0) / HORIZON_FADE)
end

-- **How far the sun and the moon's orbit is tilted out of the vertical
-- plane**, and who decides it.
--
-- Luanti's default orbit is axis-aligned: the sun rises due east, passes
-- through the zenith and sets due west, and `body_orbit_tilt` is how a game
-- says otherwise. That is a poor light to draw a world by -- every hour
-- lights the same two faces of a cube, and noon drops its shadows straight
-- down -- so this client tilts it when the game has no opinion.
--
-- **A game that has an opinion is obeyed exactly, and keeps being obeyed**,
-- including when it asks for zero: a game that tilts one dimension and not
-- another means the second one, and guessing over the top of it would be
-- worse than the default it replaces.
--
-- `own` is BUILDAT_LUANTI_ORBIT_TILT where it is set, arriving through
-- luanti.world_info(). **Zero is what a comparison against official Luanti
-- wants**, because zero is what Luanti does with a game that never asks.
M.OWN_ORBIT_TILT = 22.8
local game_asked_tilt = false

function M.orbit_tilt(game_tilt, own)
	if game_tilt ~= nil then
		game_asked_tilt = true
		return game_tilt
	end
	if game_asked_tilt then
		-- It had one and has stopped sending it; that is still its sky
		return 0
	end
	if own == nil then
		return M.OWN_ORBIT_TILT
	end
	return own
end

function M.stepped_time(t)
	return math.floor((t or 12000) / SUN_STEP + 0.5) * SUN_STEP
end

function M.low_sun(t)
	t = (t or 12000) % 24000
	local d = math.min(math.abs(t - SUN_RISE), math.abs(t - SUN_DOWN))
	local u = 1 - d / RED_HALF_WIDTH
	if u <= 0 then
		return 0
	end
	return u * u * (3 - 2 * u)
end

-- How much of SUN_TINT the light shines with at this hour
function M.sun_tint_share(t)
	local low = M.low_sun(t)
	return (1 - (1 - low) * (1 - low)) * SUN_TINT_SHARE
end

-- Where the sun is, as a direction to it, with y the sine of its elevation.
-- Luanti's own: the day is stretched so the night takes less than half of it
-- (getWickedTimeOfDay), and the sun rises towards +X and sets towards -X.
--
-- tilt is Luanti's body_orbit_tilt in degrees, which turns the orbit about
-- the axis the sun rises over -- sky.cpp does it as rotateYZBy, so it is the
-- y and z of the direction that turn and the elevation this answers with is
-- the tilted one.
function M.sun_direction(t, tilt)
	t = ((t or 12000) % 24000) / 24000
	local wn = 0.415 / 2
	local w
	if t > wn and t < 1 - wn then
		w = (t - wn) / (1 - wn * 2) * 0.5 + 0.25
	elseif t < 0.5 then
		w = t / wn * 0.25
	else
		w = 1 - (1 - t) / wn * 0.25
	end
	local a = math.rad(w * 360 - 90)
	local x, y, z = math.cos(a), math.sin(a), 0
	if tilt and tilt ~= 0 then
		local r = math.rad(tilt)
		local c, sn = math.cos(r), math.sin(r)
		y, z = y * c - z * sn, y * sn + z * c
	end
	return x, y, z
end

-- The light the sky has before the sun is up ([DAWN_LIGHT]), as a day
-- factor: zero below PREDAWN_LOW, PREDAWN_PEAK at the horizon, and nothing
-- at all above it, where the day's own ramp is larger anyway and takes over
-- without a step. height is the sine of the sun's elevation.
--
-- It opened at -18 degrees, where the stretched day puts 4:00 and the user
-- saw a bright halo over black ground; [DUSK_SKY] opens it at -24, 03:40
-- and 20:20, where the user put the starry sky fully uncovered -- the stars
-- are (1 - day)^2 -- rather than ten minutes before the glow is gone. The
-- peak is official's time_to_daynight_ratio around daybreak (0.25 at 4:52,
-- 0.35 at 5:07).
local PREDAWN_LOW = -0.403
local PREDAWN_PEAK = 0.3

-- low is where it opens, PREDAWN_LOW unless the client says (the extension
-- opens at -18 degrees, without vanilla's [DUSK_SKY] band to meet)
function M.predawn(height, low)
	low = low or PREDAWN_LOW
	if not height or height >= 0 or height <= low then
		return 0
	end
	-- BUILDAT_LUANTI_NO_PREDAWN=1 turns it off, which is how dawn_light.sh
	-- reads the same hours with and without it
	local off = buildat.get_env("BUILDAT_LUANTI_NO_PREDAWN")
	if off and off ~= "" then
		return 0
	end

	return PREDAWN_PEAK * (height - low) / -low
end


if not (buildat.get_env("BUILDAT_LUANTI_NO_PREDAWN") or ""):find("%S") then
	assert(M.predawn(0.2) == 0 and M.predawn(-0.5) == 0,
			"nothing above the horizon and nothing before it begins")
	assert(math.abs(M.predawn(-0.0001) - PREDAWN_PEAK) < 0.001,
			"and it peaks at the horizon")
	-- Where it hands over: the day's own ramp is the larger of the two from
	-- about -6 degrees up, so nothing steps at the crossing
	local ramp = function(h) return math.max(0, math.min(1, (h + 0.15) / 0.3)) end
	assert(ramp(-0.05) > M.predawn(-0.05), "the day's ramp wins near the horizon")
	assert(ramp(-0.25) < M.predawn(-0.25), "and this one before it")
end

-- What the schedule has to hold, checked at load: the two
-- never leave the sky empty between them, the moon is out of the way by the
-- time the sun is worth anything, and the clock agrees with where the sun
-- actually is.
do
	assert(M.above_horizon(-1) == 0 and M.above_horizon(0) == 0 and
			M.above_horizon(1) == 1, "the horizon line")

	-- Who decides the orbit's tilt, in the order it has to be decided in.
	-- The stickiness is the point: a game that has spoken once is obeyed
	-- from then on, zero included.
	assert(M.orbit_tilt(nil, nil) == M.OWN_ORBIT_TILT,
			"nobody asked, so it is ours")
	assert(M.orbit_tilt(nil, 0) == 0, "the client was told to use zero")
	assert(M.orbit_tilt(30, nil) == 30, "the game asked for thirty")
	assert(M.orbit_tilt(nil, 45) == 0,
			"the game has had an opinion, so ours stays out of it")
	assert(M.orbit_tilt(0, nil) == 0, "and it may ask for zero")
	-- The check itself was the game that had spoken: the stickiness it
	-- proves outlived it, and every real client ran at zero. Forgotten
	-- here so the first real call is the first.
	game_asked_tilt = false
	assert(M.orbit_tilt(nil, 22) == 22, "and the check leaves no opinion")
	assert(M.sun_amount(12000) == 1 and M.moon_amount(12000) == 0, "noon")
	assert(M.sun_amount(0) == 0 and M.moon_amount(0) == 1, "midnight")
	assert(M.moon_amount(SUN_RISE) > 0.4,
			"the moon is still up at sunrise")
	assert(M.moon_amount(MOON_OUT) == 0 and M.sun_amount(MOON_OUT) > 0.4,
			"the sun has the sky to itself once the moon is gone")
	assert(M.sun_amount(SUN_DOWN) == 0 and M.moon_amount(SUN_DOWN) > 0.4,
			"the moon is up by the time the sun is gone")

	local function elevation(t)
		local _, y = M.sun_direction(t)
		return y
	end
	assert(math.abs(elevation(SUN_RISE)) < 0.02, "the sun rises at 05:00")
	assert(math.abs(elevation(SUN_DOWN)) < 0.02, "the sun sets at 19:00")
	assert(elevation(12000) > 0.9, "the sun is overhead at noon")
	assert(elevation(0) < -0.9, "the sun is under the world at midnight")

	assert(M.low_sun(SUN_RISE) == 1 and M.low_sun(SUN_DOWN) == 1,
			"reddest as the sun crosses")
	assert(M.low_sun(12000) == 0 and M.low_sun(0) == 0,
			"nothing of it at noon or at midnight")
	assert(M.sun_tint_share(SUN_RISE) > 0.89,
			"crossing the horizon the light is nearly all the tint")
	assert(M.sun_tint_share(12000) == 0, "and at noon it is its own colour")
	-- And that what it hands over to is a red rather than a warm white,
	-- which is the whole of what the window is for
	assert(M.SUN_TINT.r - M.SUN_TINT.b > 0.5, "the low sun is red")

	-- The step is a step and nothing more
	assert(M.stepped_time(12049) == 12000 and M.stepped_time(12051) == 12100,
			"the shadow's direction is held still a step at a time")

	-- And a tilted orbit turns the sun out of the vertical plane without
	-- changing how far round the day it is
	local tx, ty, tz = M.sun_direction(12000, 30)
	local ux, uy, uz = M.sun_direction(12000)
	assert(math.abs(tx - ux) < 1e-9, "a tilt leaves the rising axis alone")
	assert(tz > 0.4 and ty < uy,
			"and takes the sun off the vertical plane at noon")
end

-- [PBR_FIT] term 1 (here from apps/vanilla since [LC_PBR_PARITY]): on the
-- pbr path the sun and the sky are in the path-traced reference's units,
-- read off its EXRs (doc/plan/rendering_plan.md, the fit's first term);
-- vanilla's SUN_BRIGHTNESS, MOON_BRIGHTNESS, SKY_AMBIENT and NIGHT_AMBIENT
-- are the parity modes' alone. The metering takes the absolute scale; what these set is the
-- ratio of sun to sky to moon, which is what contrast is made of.
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
-- How far under our horizon the sun still lights the clouds: the dip of
-- the horizon from 7 km up, acos(R / (R + h)), in sine
PHYS.cloud_dip = 0.047
do
	local hr, _, hb = PHYS.sun_rgb(1)
	local lr, _, lb = PHYS.sun_rgb(0)
	assert(hb / hr > 0.75 and lb / lr < 0.05,
			"white overhead, red on the horizon")
end
M.PHYS = PHYS

-- **The weather** ([VANILLA_WEATHER] 1): what a game's partial sky
-- commands come to as a sky, the same in both clients, which had drifted
-- apart (vanilla read the clouds' density alone, so VoxeLibre's rain left
-- its sun out). Generic, keyed on no game's name: a game that sends
-- nothing unusual comes out as before. Colours are {r, g, b} 0..1.
local function clamp01(v) return math.max(0, math.min(1, v)) end
local function lum(c) return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b end

-- Luanti's own cloud density, which every game gets whether or not it asks
M.CLOUD_DENSITY_DEFAULT = 0.4
-- Luanti's own cloud speed, nodes a second on x and z, and what one node
-- a second is in SkyDome's units. simplified: the dome's clouds are no
-- layer at a height (the shader divides the view by its y), so a speed has
-- nothing exact to become; the factor makes the default drift at the rate
-- the shader had baked in, and twice the speed twice as fast. See
-- doc/luanti_client.txt.
M.CLOUD_SPEED_DEFAULT = {0, -2}
M.CLOUD_WIND_PER_NODE = 0.0054
-- Luanti's own cloud colour is 229 of 255 opaque, and a colour named
-- without an alpha is a full one
M.CLOUD_ALPHA_DEFAULT = 229 / 255
-- What a full overcast takes from the sun and the moon (a named pick)
M.CLOUD_DIM = 0.8
-- A cloud need not be black to be opaque
local CLOUD_SHADE_GAIN = 1.3
-- What a full overcast takes from the zenith where the game's own day
-- colours are not drawn (pbr draws the reference's), a named pick
M.OVERCAST_DIM = 0.6

-- **How much of the sky is cloud**, 0..1, out of the two ways a game says
-- it: the density above Luanti's default 0.4, and the colour -- VoxeLibre
-- never touches the density and darkens the clouds instead, #FFF0F0
-- clear, #5D5D5F rain, #3D3D3F thunder. A black cloud that covers nothing
-- shades nothing, so the colour is weighed by whether there is a layer.
-- on: false when the game turned the clouds off (set_sky clouds = false).
function M.cloud_cover(density, color, on)
	if on == false then
		return 0
	end
	density = density or M.CLOUD_DENSITY_DEFAULT
	local have = clamp01(density / M.CLOUD_DENSITY_DEFAULT)
	local dense = clamp01((density - M.CLOUD_DENSITY_DEFAULT) /
			(1 - M.CLOUD_DENSITY_DEFAULT))
	local shade = color and clamp01((1 - lum(color)) * CLOUD_SHADE_GAIN * have)
			or 0
	return 1 - (1 - dense) * (1 - shade)
end

-- **A body's direct light**, 0..1: none from a hidden sun or moon -- a gate,
-- not a dimming; VoxeLibre hides the sun, the moon and the stars in bad
-- weather, a dimension with no sky for good -- and what the cloud leaves
-- of a visible one. The sky's own diffuse light is the callers' and stays.
function M.direct_light(visible, cover)
	if visible == false then
		return 0
	end
	return 1 - M.CLOUD_DIM * (cover or 0)
end

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
function M.flash_radiance()
	return M.FLASH * PHYS.sky_zenith
end
-- How much a game's sky colour ({r,g,b} 0..1) says flash: white, each
-- channel near one, which no daylight sky is
function M.sky_flash(c)
	if not c then
		return 0
	end
	return clamp01((math.min(c.r, c.g, c.b) - 0.9) / 0.1)
end

-- What the games really send, in and out ([VANILLA_WEATHER]'s checks)
do
	local function rgb(hex)
		return {r = tonumber(hex:sub(1, 2), 16) / 255,
				g = tonumber(hex:sub(3, 4), 16) / 255,
				b = tonumber(hex:sub(5, 6), 16) / 255}
	end
	-- VoxeLibre: the density stays 0.4, the weather in the colour
	local clear = M.cloud_cover(0.4, rgb("FFF0F0"))
	local rain = M.cloud_cover(0.4, rgb("5D5D5F"))
	local thunder = M.cloud_cover(0.4, rgb("3D3D3F"))
	local snow = M.cloud_cover(0.4, rgb("ADADAD"))
	assert(clear < 0.1, "a clear sky keeps the sun")
	assert(snow > 0.3 and snow < rain, "snow takes some, less than rain")
	assert(rain > 0.6 and rain < thunder, "rain takes most of it")
	assert(thunder > 0.9, "a thunderstorm takes nearly all of it")
	-- The Nether, the End and the void: no clouds, nothing from them; the
	-- bodies hidden, so no direct light whatever the cover
	assert(M.cloud_cover(0.4, rgb("3D3D3F"), false) == 0, "no clouds, no cover")
	assert(M.direct_light(false, 0) == 0, "a hidden body lights nothing")
	assert(M.direct_light(true, 0) == 1, "a clear sky's sun is whole")
	assert(M.direct_light(true, thunder) < 0.3, "a storm leaves little sun")
	-- Minetest Game and devtest: the defaults, a white cloud -- the sky
	-- as it was
	local mtg = M.cloud_cover(0.4, rgb("F0F0FF"))
	assert(mtg < 0.1, "a default sky is clear")
	local z, h = {r = 0.4, g = 0.6, b = 1.0}, {r = 0.6, g = 0.7, b = 0.9}
	local z2, h2 = M.overcast(z, h, rgb("F0F0FF"), 0)
	assert(z2 == z and h2 == h, "no cover changes nothing")
	-- A game that says it with the density
	assert(M.cloud_cover(1.0, rgb("FFFFFF")) > 0.9, "a full sky covers it")
	assert(M.cloud_cover(0.0, rgb("000000")) == 0, "no layer covers nothing")
	-- Under a thunderstorm: grey, the horizon a third of the zenith
	local zt, ht = M.overcast(z, h, rgb("3D3D3F"), 1, 0)
	assert(math.abs(lum(ht) - lum(zt) / 3) < 1e-6, "the horizon a third")
	assert(math.abs(zt.r - zt.b) < 0.05 * lum(zt), "the clouds' grey")
	local zd = M.overcast(z, h, rgb("5D5D5F"), 1, M.OVERCAST_DIM)
	assert(lum(zd) < lum(z) * 0.5, "pbr's zenith darkens under cover")
	-- VoxeLibre's lightning layer is white; its clear and its snow skies
	-- are not a flash
	assert(M.sky_flash(rgb("FFFFFF")) > 0.99, "a white sky flashes")
	assert(M.sky_flash(rgb("78A7FF")) == 0, "a day sky does not")
	assert(M.sky_flash(rgb("ADADAD")) == 0, "a snow sky does not")
	assert(M.flash_radiance() > PHYS.sky_zenith, "over the noon sky")
end

return M
