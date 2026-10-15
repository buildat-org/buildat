-- Buildat: builtin/luanti/client_lua/sky_light.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The pbr path's light, as rules ([SKELDAT_LUANTI_PARTS] 3): what the sun,
-- the sky, the bounce, the ground, a lamp and a sealed cave give a face at
-- a sun height, the sky's radiance in a hue, the fog, the clouds' light,
-- and the render path that meters and tonemaps the frame. builtin/luanti's
-- client loop (client.lua) and any other game's (apps/demo_skeldat) call
-- these and apply them each to its own scene. The rules themselves are
-- extensions/physical_sky's (the sky) and extensions/voxel_light's (the
-- light), re-exported here; what is this file's own is the render path.
-- No state: the caller keeps its zone, lights and sky.
local ok, err, sky_dome = buildat.run_script_file("luanti/sky_dome.lua")
if not ok or type(sky_dome) ~= "table" then
	error("luanti: could not load sky_dome.lua: " .. tostring(err))
end
local PHYS = sky_dome.PHYS
local physical_sky = sky_dome.physical_sky

local M = {}
M.PHYS = PHYS
-- The sky's own rules ([LC_SKY_SHARED]): physical_sky's, here for the
-- callers that read them through this table
for _, name in ipairs({"sky_radiance", "dome", "outside", "fog", "sun_disc",
		"cloud_lit"}) do
	M[name] = physical_sky[name]
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

-- The light terms are extensions/voxel_light's ([LC_SKY_SHARED] 2), the
-- copy voxel_shading's server serves, over the sky above
local ok_vl, err_vl, voxel_light =
		buildat.run_script_file("voxel_light/init.lua")
if not ok_vl or type(voxel_light) ~= "table" then
	error("luanti: could not load voxel_light: " .. tostring(err_vl))
end
M.MOON_COLOR = voxel_light.MOON_COLOR
M.TEXEL_K = voxel_light.TEXEL_K
M.lamp_curve = voxel_light.lamp_curve
M.object_light = voxel_light.object_light

function M.terms(height, dome)
	return voxel_light.terms(physical_sky, height, dome)
end

-- voxel_light.apply() onto voxel_shading and the zone
function M.apply(voxel_shading, zone, magic, t, translucency)
	return voxel_light.apply({
		ambient = function(r, g, b) zone.ambientColor = magic.Color(r, g, b) end,
		bounce = voxel_shading.set_bounce_light,
		lamp = voxel_shading.set_lamp_light,
		ground = voxel_shading.set_ground_light,
		translucency = voxel_shading.set_translucency_gain,
		chamber = voxel_shading.chamber_light,
		cave_ambient = voxel_shading.set_cave_ambient,
		chamber_light = voxel_shading.set_chamber_light,
	}, PHYS, t, translucency)
end

do
	local z, h = M.sky_radiance(PHYS.day_zenith, PHYS.day_horizon, 1)
	local noon = M.terms(1, M.dome(z, h))
	local night = M.terms(-0.5, M.dome(M.sky_radiance(PHYS.day_zenith,
			PHYS.day_horizon, -0.5)))
	assert(noon.sky.b > noon.sky.r and noon.ambient.g > 1,
			"noon's sky light is blue and bright")
	assert(night.sun == 0 and night.ambient.g < 0.01, "the night's is dark")
end

return M
-- vim: set noet ts=4 sw=4:
