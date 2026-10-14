-- Buildat: vanilla/client_lua/sky_dome.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The sky, drawn by `extensions/shaders/res/SkyDome.glsl` rather than
-- builtin/voxel_shading's skybox.
--
-- The same shader draws extensions/luanti_client's sky and the
-- floorplanner's: a gradient, the sun and the moon, the stars, the dawn
-- glow, the dusk band, the treeline and a flat cloud layer.
--
-- **What this is not** is a new sky. The launcher works out what colour the
-- sky is at this hour, how far the sun has got and how many stars are out,
-- and goes on doing exactly that; this only takes those answers to a
-- different shader, whose parameters have different names and one different
-- shape. Where the two disagree is written down at each call.
--
-- **Every uniform is set here at creation**, including the ones nothing ever
-- changes: a shader parameter a material never sets reads as zero, and zero
-- for most of these is a black sky.
local log = buildat.Logger("vanilla")
local magic = require("buildat/extension/urho3d")

local M = {}

-- How fast the cloud layer drifts. Luanti's own default is two nodes a
-- second; SkyDome counts in its own units and says so.
local CLOUD_WIND = {x = 0.004, y = 0.0}
-- How far past white the sun's disc is drawn, which is what makes it read as
-- a light rather than a white circle. The extension's own value.
local SUN_OVEREXPOSURE = 2.5
local ok_model, err_model, model =
		buildat.run_script_file("luanti/sky_model.lua")
if not ok_model or type(model) ~= "table" then
	error("vanilla: could not load sky_model.lua: " .. tostring(err_model))
end
-- The schedule, the sun's direction and the predawn light are the model
-- both clients share (res/sky_model.lua); this file is vanilla's drawing
-- of them
for k, v in pairs(model) do M[k] = v end

local function clamp01(v)
	return v < 0 and 0 or (v > 1 and 1 or v)
end

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

-- **Luanti's dusk colours** ([DUSK_PARITY], the parity modes): its
-- directional coloured fog, on by default, mixes the horizon half way and
-- the top a quarter towards a point colour -- the sun's facing the sun, the
-- moon's away from it -- and the clouds a quarter. By the clock, not the
-- sun: from 18:00 to 20:24, the most at 19:12; 03:36 to 06:00 at dawn.
-- Sky::m_horizon_blend() as it stands. The sky here takes the two along
-- its azimuth rather than by the camera's (init.lua, user 2026-10-06).
function M.horizon_blend(tod)
	local x = tod >= 0.5 and (1 - tod) * 2 or tod * 2
	if x <= 0.3 or x > 0.5 then
		return 0
	elseif x <= 0.4 then
		return (x - 0.3) * 10
	end
	return (0.5 - x) * 10
end
-- The two point colours at a time_brightness (Luanti's decode_light of the
-- day/night ratio, display units): Sky::update()'s own formula for
-- "default" tinting -- the sun's tonemap branch is left out, the base
-- pack having no sun_tonemap.png -- and the game's two for "custom", where
-- the sun's is not dimmed and the moon's is.
function M.point_colors(tb, sky)
	local function clamp(v, a, b) return math.max(a, math.min(b, v)) end
	local pl = clamp(tb * 3, 0.2, 1)
	local custom = sky and sky.fog_tint_type == "custom"
	local sun
	if custom and sky.sun_tint then
		sun = sky.sun_tint
	else
		local b = pl * (0.25 + (clamp(tb, 0.25, 0.75) - 0.25) * 1.5)
		sun = {r = pl, b = b,
				g = pl * (b * 0.375 + (clamp(tb, 0.05, 0.15) - 0.05) * 6.25)}
	end
	local mt = custom and sky.moon_tint or {r = 0.5, g = 0.6, b = 0.8}
	return sun, {r = mt.r * pl, g = mt.g * pl, b = mt.b * pl}
end
assert(math.abs(M.horizon_blend(0.8) - 1) < 1e-9 and
		math.abs(M.horizon_blend(0.2) - 1) < 1e-9, "the most at 19:12 and 04:48")
assert(M.horizon_blend(0.75) == 0 and M.horizon_blend(0.86) == 0 and
		M.horizon_blend(0.5) == 0, "nothing by day or at night")
assert(M.point_colors(0.1).b < M.point_colors(0.1).r * 0.5, "the low sun's is orange")

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
-- from 19:30 on (SkyDome's cDuskBand.z)
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


function M.new(scene, sun_dir, defaults)
	local node = scene:CreateChild("SkyDome")
	local box = node:CreateComponent("Skybox")
	box:SetModel(magic.cache:GetResource("Model", "Models/Box.mdl"))
	local material = magic.Material:new()
	material:SetTechnique(0, magic.cache:GetResource("Technique",
			"shaders/res/SkyDome.xml"))
	-- SkyDome.xml says cull="none" itself, unlike Urho3D's own skybox
	-- technique; a box seen from the inside is entirely back-facing, and a
	-- material that does not say so draws nothing at all.
	box.material = material

	local self = {node = node, material = material}

	-- Each parameter set only when it changes: update_sky() tells the sky
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
	-- And the two bodies' pictures, by the same rule
	local sun_texture_now, moon_texture_now = nil, nil

	-- The cloud colour is a colour here where builtin/voxel_shading takes a
	-- brightness and has the colour baked in, so both halves are kept and
	-- the parameter is written from the two together.
	local cloud_rgb = {r = 0.9, g = 0.92, b = 0.95}
	local cloud_light = defaults.cloud_light or 1.0

	-- And a colour mixed into it at a share, [DUSK_PARITY]'s
	local cloud_tint, cloud_tint_k = nil, 0

	local function put_cloud()
		local c = {r = cloud_rgb.r * cloud_light,
				g = cloud_rgb.g * cloud_light, b = cloud_rgb.b * cloud_light}
		if cloud_tint then
			local k = cloud_tint_k
			c = {r = c.r + (cloud_tint.r - c.r) * k,
					g = c.g + (cloud_tint.g - c.g) * k,
					b = c.b + (cloud_tint.b - c.b) * k}
		end
		set("CloudColor", c.r, c.g, c.b)
	end

	-- Everything, at what the sky looked like before any game said anything
	set("SunDirection", -sun_dir.x, -sun_dir.y, -sun_dir.z)
	set("SkyTop", defaults.zenith.r, defaults.zenith.g, defaults.zenith.b)
	set("SkyHorizon", defaults.horizon.r, defaults.horizon.g, defaults.horizon.b)
	set("SunTint", defaults.sun_color.r, defaults.sun_color.g,
			defaults.sun_color.b)
	set("SunSize", defaults.sun_half)
	set("SunOverexposure", SUN_OVEREXPOSURE)
	-- The moon is a body of its own here, drawn opposite the sun. Half its
	-- width is Luanti's own ratio to the sun's, which the extension carries
	-- as MOON_HALF.
	set("MoonSize", M.MOON_HALF)
	set("MoonTextured", 0.0)
	set("SunTextured", 0.0)
	set("StarDensity", 0.0)
	set("StarColor", 0.9, 0.9, 1.0)
	set("StarFade", 0.0)
	set("CloudCoverage", defaults.cloud_cover)
	set("CloudAlpha", 1.0)
	set("CloudWind", CLOUD_WIND.x, CLOUD_WIND.y)
	-- What a player who cannot see the sky is under, and whether the game
	-- allows the dimming at all. Luanti's own indoors default is #646464
	-- and auto_dim_skybox is on; see set_indoors() below and [CAVE_SKY].
	set("SkyIndoors", 0.39, 0.39, 0.39)
	set("SkyAutoDim", 1.0)
	put_cloud()

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

	function self:set_cloud_light(k)
		if k == nil then
			return
		end
		cloud_light = math.max(0, k)
		put_cloud()
	end

	function self:set_cloud_tint(c, k)
		cloud_tint, cloud_tint_k = c, k or 0
		put_cloud()
	end

	function self:set_cloud_color(c)
		if c == nil then
			return
		end
		cloud_rgb = {r = c.r or 0.9, g = c.g or 0.92, b = c.b or 0.95}
		put_cloud()
	end

	-- Half the width of the square, and what colour it is. Zero turns it
	-- off, which is how a game says its sun or its moon is not there.
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

	-- [DUSK_PARITY]: the band round the low sun, share of it in the
	-- glow's orange at this many times the sky's level, as on pbr, and
	-- the glow towards the sun only
	function self:set_parity_band(band, share, glow)
		set("DawnGlow", glow.r, glow.g, glow.b)
		set("DuskBand", band, 0, share)
	end

	-- The game's own picture of it, or nil for the shader's painted square.
	-- SkyDome reads the sun's from sDiffMap and the moon's from
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
	-- size; SkyDome keeps the two apart and has no size. So the count goes
	-- to the density and the night ramp goes to the fade, which is the
	-- better shape: stars come out rather than appearing one by one.
	function self:set_star_look(density, color, fade)
		set("StarDensity", math.max(0, density or 0))
		set("StarFade", math.max(0, math.min(1, fade or 1)))
		if color then
			set("StarColor", color.r or color[1] or 0.9, color.g or color[2] or 0.9,
					color.b or color[3] or 1.0)
		end
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

	-- The gradient shaped as the path trace's rather than as Luanti's; see
	-- cSkyPhysical in the shader
	function self:set_physical(on)
		set("SkyPhysical", on and 1.0 or 0.0)
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

	log:info("the sky is Luanti's own shader")
	return self
end

return M
-- vim: set noet ts=4 sw=4:
