-- Buildat: builtin/luanti/client_lua/sky_light.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The pbr path's light, as rules ([SKELDAT_LUANTI_PARTS] 3): what the sun,
-- the sky, the bounce, the ground, a lamp and a sealed cave give a face at
-- a sun height, the sky's radiance in a hue, the fog, the clouds' light,
-- and the render path that meters and tonemaps the frame. builtin/luanti's
-- client loop (client.lua) and any other game's (apps/demo_skeldat) call
-- these and apply them each to its own scene; the numbers and why they are
-- what they are live in res/sky_model.lua's PHYS and in sky_dome.lua.
-- No state: the caller keeps its zone, lights and sky.
local ok, err, sky_dome = buildat.run_script_file("luanti/sky_dome.lua")
if not ok or type(sky_dome) ~= "table" then
	error("luanti: could not load sky_dome.lua: " .. tostring(err))
end
local PHYS = sky_dome.PHYS

local M = {}
M.PHYS = PHYS

local function lum(c)
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
end

-- [PT_EXPOSURE]: the meter -- Urho3D's AutoExposure.xml, log-average
-- luminance as the key, clamped to the range, the frame scaled by middle
-- grey over it -- which is the path-traced reference's own rule
-- (pathtrace_render.py, LUM_RANGE and MIDDLE_GREY). The adaptation rate
-- is a client's: a still has no time axis.
-- The floor is how far the eye may adapt into the dark: 0.05 was a
-- daylight-adapted eye looking at the night, and the moonlit snow field
-- rendered pitch black under it. 0.003 put that field's probe at a median
-- of 39 of 255 with the sky still at 0 ([PT_NIGHT]'s target). **0.015
-- caps the gain at 12x** ([CAVE_EXPOSURE_FLOOR], user 2026-10-08: a cave
-- dark on the screen, not metered up to grey). pbr_pair.sh's medians: a
-- closed cave 49 (101 at 0.003), its moonlit snow field 37 (74); at 0.04
-- 31 and 24.
-- **The top is vp5_1000's own key** (user, 2026-10-01: its greenery sets a
-- good snow exposure, and a field of snow and ice should keep it rather
-- than be metered down to dull): 7.04 there. It is the highest key of the
-- reference views (vp1_1300 is 3.0, the rest under 2), so the cap changes
-- none of them; pathtrace_render.py's 100 is left alone.
M.EXPOSURE = {adapt_rate = 0.6, lum_range = {0.015, 7.0}, middle_grey = 0.18}

-- The frame's path, on a clone of `base`. opt: linear (the metered frame
-- clipped, no curve, no bloom, no gray: what the reference's PNGs are and
-- what a probe reads), tonemap ("uncharted2" or "aces"), gray_off, gray
-- ({L0, L1}: the night gray pass's levels), adapt_rate and lum_range
-- (the meter's, else M.EXPOSURE's).
function M.render_path(magic, base, opt)
	opt = opt or {}
	local rp = base:Clone()
	-- The gray of the eye's rods first, before the meter: the pass reads
	-- the scene's radiance in the reference's units ([NIGHT_GRAY]).
	-- (0.0003, 0.003) is the user's pick off the second ladder (2026-09-21):
	-- the caves whole, the night with a trace of green; in the xml.
	-- **The pass stays on unless it is asked off** (2026-09-26): taking it
	-- out took the night with it -- vp4 at 20:30 went from a mean of 8 to
	-- 109 -- and it does not compound with the shader's gray
	-- (voxel_shading.set_gray_by_light), which acts only under the cave
	-- floor's own luminance; the pass's range is a hundredth of that.
	rp:Append(magic.cache:GetResource("XMLFile",
			"luanti_client/res/NightGray.xml"))
	rp:SetEnabled("NightGray", not opt.gray_off and not opt.linear)
	if opt.gray then
		rp:SetShaderParameter("NightGray",
				magic.Vector2(opt.gray[1], opt.gray[2]))
	end
	-- The exposure first and the bloom after it: the bloom's threshold is
	-- a screen value, and taken before the exposure on a world at the
	-- reference's radiances ([PBR_FIT], a sky of 5 and snow of 30) it
	-- passed every pixel, and the blur it mixed back in was a haze that
	-- took the shadows with it.
	rp:Append(magic.cache:GetResource("XMLFile",
			"shaders/res/AutoExposureMean.xml"))
	rp:Append(magic.cache:GetResource("XMLFile", "PostProcess/BloomHDR.xml"))
	-- The curve: Urho's per-channel Uncharted2, picked by the user off the
	-- pair for its range in caves ([PBR_FIT] term 4, 2026-09-20); ACES
	-- (luanti_client/res/TonemapACES) on asking
	rp:Append(magic.cache:GetResource("XMLFile", "PostProcess/Tonemap.xml"))
	rp:Append(magic.cache:GetResource("XMLFile",
			"luanti_client/res/TonemapACES.xml"))
	rp:Append(magic.cache:GetResource("XMLFile",
			"PostProcess/GammaCorrection.xml"))
	rp:SetEnabled("TonemapReinhardEq3", false)
	local aces = opt.tonemap == "aces"
	rp:SetEnabled("TonemapUncharted2", not opt.linear and not aces)
	rp:SetEnabled("TonemapACES", not opt.linear and aces)
	-- and no bloom when linear: the render has none, and a bright pass
	-- blurred over a probe crop is a white the crop did not earn
	rp:SetEnabled("BloomHDR", not opt.linear)
	-- The bloom's threshold is against the exposed frame, so it sits where
	-- that frame clips (the tonemap's shoulder starts above 1.0); a fifth
	-- of 15% mixed (user, 2026-09-20, [BLOOM_FIFTH]; the grade's ladder
	-- kept it, 2026-09-21, [PBR_GRADE]).
	rp:SetShaderParameter("BloomHDRThreshold", 1.2)
	rp:SetShaderParameter("BloomHDRMix", magic.Vector2(1.0, 0.03))
	-- No bias on top of the meter: the meter owns the level and a bias is
	-- a second exposure that pushes the lit parts up the curve's shoulder
	-- ([PBR_FIT] term 4)
	rp:SetShaderParameter("TonemapExposureBias", 1.0)
	-- Uncharted2's white point: 2, the grade's ladder's pick (user,
	-- 2026-09-21, [PBR_GRADE]; Urho's own is 4.0)
	rp:SetShaderParameter("TonemapMaxWhite", 2.0)
	local range = opt.lum_range or M.EXPOSURE.lum_range
	rp:SetShaderParameter("AutoExposureAdaptRate",
			opt.adapt_rate or M.EXPOSURE.adapt_rate)
	rp:SetShaderParameter("AutoExposureLumRange",
			magic.Vector2(range[1], range[2]))
	rp:SetShaderParameter("AutoExposureMiddleGrey", M.EXPOSURE.middle_grey)
	-- A game's set_lighting() saturation, last; off until asked for
	rp:Append(magic.cache:GetResource("XMLFile",
			"luanti_client/res/Saturation.xml"))
	return rp
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

M.MOON_COLOR = {r = 1.0, g = 0.86, b = 0.70}

-- What a face gets at a sun height under a dome of that hue (M.dome()):
--   sun, sun_color   the sun's irradiance and colour (PHYS.sun_rgb)
--   moon, moon_color the moon's: the render's, a 4100 K lamp -- the cold
--                    blue is the parity modes' look, and the night probe
--                    read pbr's snow blue against the render's warm
--                    ([NIGHT_LIGHT], 2026-09-20)
--   sky              a face with the whole sky, the dome's hue at its mean
--   ambient          sky plus [DAWN_LIGHT]'s share of the glow
--   bounce, ground, lamp, sun_level (the sun on a level face)
--   glow, glow_tint  the glow on the sky's band (sky_dome's set_dawn_glow)
function M.terms(height, dome)
	local t = {}
	t.sun = PHYS.sun(height)
	local sr, sg, sb = PHYS.sun_rgb(height)
	t.sun_color = {r = sr, g = sg, b = sb}
	t.moon = PHYS.moon_e
	t.moon_color = M.MOON_COLOR
	-- The sky's mean radiance, which the shader multiplies by how much sky
	-- a face sees. What a horizontal face receives over pi: the render's
	-- grass (albedo 0.036) reads 1.50 sunlit at 13:00 and 0.15 in the
	-- shade at 05:45, which leaves the dome at about the zenith's radiance
	-- -- the horizon's band is bright but at a grazing weight. PHYS.dome of
	-- it: the render's snow in an open shadow at 10:00 reads (1.6, 3.0,
	-- 5.3), which off snow's albedo is a dome of 3.2 against a drawn zenith
	-- patch of 4.5 -- Nishita's dome is bright toward the sun and dark
	-- away, and a face sees the mean.
	local mean = PHYS.night_sky +
			(PHYS.sky_zenith * PHYS.dome - PHYS.night_sky) * PHYS.sky(height)
	-- In the drawn sky's own hue, which is what a shadow on snow is lit by:
	-- the render's reads (1.6, 3.0, 5.3), the sky's blue, where a grey
	-- ambient gave a grey shadow
	local l = lum(dome)
	local k = l > 1e-6 and mean / l or 0
	t.sky = {r = dome.r * k, g = dome.g * k, b = dome.b * k}
	-- [DAWN_LIGHT]'s glow: on the sky's band, and a share of it added to
	-- the three ambient terms in its orange -- each of which the shader
	-- gates by the face's sky, so a sealed chamber keeps its dark; never
	-- into the cave floor
	local glow = sky_dome.dawn_glow(height)
	local gc = sky_dome.DAWN_COLOR
	local ga, gs = glow * sky_dome.DAWN_AMBIENT, glow * sky_dome.DUSK_SKY
	t.glow = {r = gs * gc.r, g = gs * gc.g, b = gs * gc.b}
	t.glow_tint = sky_dome.dusk_tint(height)
	t.ambient = {r = t.sky.r + ga * gc.r, g = t.sky.g + ga * gc.g,
		b = t.sky.b + ga * gc.b}
	-- What a face the sky does not reach gets instead: light off the
	-- surroundings, a share of the sky's mean in its hue ([PBR_FIT] term
	-- 2), fitted to the render's cave mouth. simplified: one share for the
	-- whole day; the render's cave at other hours is what would fit it
	-- further.
	t.bounce = {r = t.ambient.r * PHYS.bounce, g = t.ambient.g * PHYS.bounce,
		b = t.ambient.b * PHYS.bounce}
	-- A lamp at full in the sky's units: PHYS.lamp, in the glowstone's own
	-- orange, at a torch's own faces ([TORCH_LIGHT]). simplified: one level
	-- and one colour for every light source; a torch is not a glowstone.
	t.lamp = {r = PHYS.lamp * 1.0, g = PHYS.lamp * 0.6, b = PHYS.lamp * 0.3}
	-- The sun on a level face, over pi
	t.sun_level = t.sun * math.max(height, 0) / math.pi
	-- And the ground as the lower hemisphere sees it: its albedo times what
	-- falls on it, the sky on all of it and a third of the sun, over pi. A
	-- third, not the half that is lit on average: the ground a shaded wall
	-- faces is partly in the same shadow, and the base pass has no shadow
	-- map to say which ([PBR_FIT], contrast_dirt against
	-- contrast_dirt_pit). simplified: one albedo for every ground.
	local s = t.sun_level
	t.ground = {
		r = PHYS.ground.r * (s * sr + t.ambient.r),
		g = PHYS.ground.g * (s * sg + t.ambient.g),
		b = PHYS.ground.b * (s * sb + t.ambient.b)}
	return t
end

-- M.terms() onto voxel_shading and the zone, and the cave's two: the
-- constant floor under the ambient where the chamber the camera is in is
-- dark ([CAVE_AO], PHYS.cave_floor, the same at every hour, which is what
-- [UNDERGROUND_LIGHT]'s invariant needs -- scaled by how unlit the chamber
-- is, it is the whole floor in a sealed place and nothing under an open
-- sky), and the bounce's own floor scaled by how lit the chamber is, so a
-- sealed chamber stops following the hour and a cave lit round a corner
-- keeps its light (gain 1, the user's pick, 2026-09-25). The reading is
-- the camera's rays: no face can work out what arrives round a corner,
-- and the player is taken to be in the chamber they are looking at.
-- Returns the chamber reading.
function M.apply(voxel_shading, zone, magic, t, translucency)
	local a = t.ambient
	zone.ambientColor = magic.Color(a.r, a.g, a.b)
	voxel_shading.set_bounce_light(t.bounce.r, t.bounce.g, t.bounce.b)
	voxel_shading.set_lamp_light(t.lamp.r, t.lamp.g, t.lamp.b)
	voxel_shading.set_ground_light(t.ground.r, t.ground.g, t.ground.b)
	voxel_shading.set_translucency_gain(translucency or PHYS.translucency)
	local chamber = voxel_shading.chamber_light()
	local dark = 1.0 - math.min(1.0, chamber)
	local f = PHYS.cave_floor * dark
	voxel_shading.set_cave_ambient(f, f, f)
	voxel_shading.set_chamber_light(chamber)
	return chamber
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
-- in a radiance sky. Returns the sun's and the sky's for sky_dome's
-- set_cloud_lit. The sky's share is the dome's mean as it is ([DUSK_CLOUD]:
-- a dome of radiance L puts pi L on a face, which reflects albedo L); the
-- sun's is E_sun of the hour times how high it is, times k_sun, set so
-- that at noon a thin cloud is cloud_n times the zenith patch (PHYS.cloud_n,
-- rated by the user). sun_through: what of the sun gets through
-- (sky_dome.direct_light()).
function M.cloud_lit(albedo, zenith, horizon, height, sun_through, cloud_n)
	local mean = M.dome(zenith, horizon)
	local n = cloud_n or PHYS.cloud_n
	local noon_mean = (5 * PHYS.sky_zenith + PHYS.sky_horizon) / 6
	local k_sun = math.max(0, (n * PHYS.sky_zenith / sky_dome.CLOUD_REF_LUM -
			noon_mean) * math.pi / PHYS.sun(1))
	-- The sun as the clouds see it: from 7 km up it sets PHYS.cloud_dip
	-- later, through the longer air that reddens it
	local h = height + PHYS.cloud_dip
	local e = PHYS.sun(h) * math.max(h, 0) * k_sun / math.pi * sun_through
	local sr, sg, sb = PHYS.sun_rgb(h)
	-- And the dusk glow is sky light too: what a cloud gets of it is the
	-- dome's mean of SkyDome's glow term, (1 - y)^2 over the hemisphere (a
	-- third) times away + (1 - away) of a quarter for cos^2 towards the sun
	local gm = sky_dome.dawn_glow(height) * sky_dome.DUSK_SKY *
			(sky_dome.DUSK_AWAY + (1 - sky_dome.DUSK_AWAY) / 4) / 3
	local gc = sky_dome.DAWN_COLOR
	return {r = albedo.r * e * sr, g = albedo.g * e * sg, b = albedo.b * e * sb},
		{r = albedo.r * (mean.r + gm * gc.r), g = albedo.g * (mean.g + gm * gc.g),
			b = albedo.b * (mean.b + gm * gc.b)}
end

do
	local z, h = M.sky_radiance(PHYS.day_zenith, PHYS.day_horizon, 1)
	local noon = M.terms(1, M.dome(z, h))
	local night = M.terms(-0.5, M.dome(M.sky_radiance(PHYS.day_zenith,
			PHYS.day_horizon, -0.5)))
	assert(noon.sky.b > noon.sky.r and noon.ambient.g > 1,
			"noon's sky light is blue and bright")
	assert(night.sun == 0 and night.ambient.g < 0.01, "the night's is dark")
	assert(M.outside(0) == 0 and M.outside(1) == 1, "the gate's ends")
end

return M
-- vim: set noet ts=4 sw=4:
