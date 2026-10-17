-- Buildat: builtin/luanti/client_lua/sky_dome.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The sky: extensions/sky_render's dome (physical_sky's) in pbr and
-- Luanti's own sky (extensions/luanti_client/res/LuantiSky.glsl) in the
-- parity modes, one material with the technique swapped (set_physical()),
-- rather than
-- builtin/voxel_shading's skybox. Luanti's schedule (res/sky_model.lua) and
-- physical_sky's numbers are both read through this table.
--
-- **What this is not** is a new sky. The launcher works out what colour the
-- sky is at this hour, how far the sun has got and how many stars are out,
-- and goes on doing exactly that; this only takes those answers to a
-- different shader, whose parameters have different names and one different
-- shape. Where the two disagree is written down at each call.
local magic = require("buildat/extension/urho3d")

local M = {}

local ok_model, err_model, model =
		buildat.run_script_file("luanti/sky_model.lua")
if not ok_model or type(model) ~= "table" then
	error("luanti: could not load sky_model.lua: " .. tostring(err_model))
end
-- The server's physical_sky ([LC_SKY_SHARED]), served by luanti.cpp
local ok_phys, err_phys, physical_sky =
		buildat.run_script_file("physical_sky/init.lua")
if not ok_phys or type(physical_sky) ~= "table" then
	error("luanti: could not load physical_sky: " .. tostring(err_phys))
end
M.physical_sky = physical_sky
local ok_render, err_render, sky_render =
		buildat.run_script_file("sky_render/init.lua")
if not ok_render or type(sky_render) ~= "table" then
	error("luanti: could not load sky_render: " .. tostring(err_render))
end
-- The schedule, the sun's direction and the predawn light are the model
-- both clients share (res/sky_model.lua), and the radiances, the glow and
-- the dusk ramp are physical_sky's; this file is the client loop's drawing
-- of them
for k, v in pairs(physical_sky) do M[k] = v end
for k, v in pairs(model) do M[k] = v end
M.safe = nil

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



-- log: the game's logger
function M.new(scene, sun_dir, defaults, log)
	-- sky_render's dome with Luanti's moon and clouds as it has them
	-- before a game says anything
	local self = sky_render.new_dome(scene, sun_dir, defaults, log, model)
	local set = self.set_param
	local physical_technique = magic.cache:GetResource("Technique",
			"physical_sky/PhysicalSky.xml")
	local luanti_technique = magic.cache:GetResource("Technique",
			"luanti_client/res/LuantiSky.xml")

	-- **The parity modes' own**, on the same material: Luanti's cloud
	-- colour, its dusk band and the technique.
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
	put_cloud()

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

	-- [DUSK_PARITY]: the band round the low sun, share of it in the
	-- glow's orange at this many times the sky's level, as on pbr, and
	-- the glow towards the sun only
	function self:set_parity_band(band, share, glow)
		set("DawnGlow", glow.r, glow.g, glow.b)
		set("DuskBand", band, 0, share)
	end

	-- physical_sky's in pbr, Luanti's coloured sky in the parity modes
	-- simplified: a client that changes mode mid-session keeps the disc's
	-- radiance pbr last set, which LuantiSky does not read
	local physical_now = true
	function self:set_physical(on)
		on = on and true or false
		if on ~= physical_now then
			physical_now = on
			self.material:SetTechnique(0, on and physical_technique or
					luanti_technique)
		end
	end

	return self
end

return M
-- vim: set noet ts=4 sw=4:
