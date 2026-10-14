-- Buildat: extension/luanti_client/surface.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- What a node's surface is made of, guessed from its definition.
--
-- **Both Luanti clients read this one file** ([VOXEL_MATERIALS] in
-- doc/plan/rendering_plan.md): the extension with the definition its
-- nodedef.lua parsed off the wire, builtin/luanti with the definition the
-- game registered, through core.__voxel_defs() in its bootstrap.lua. The
-- two spell a drawtype differently -- a number on the wire, a name in a
-- mod -- and both spellings are taken below; what else is read (name,
-- groups, waving, light_source) is spelled the same on both sides.
--
-- The atlas derives a normal map and a spec map from six numbers per texture
-- segment (see src/interface/atlas.h), and the PBR voxel shader reads them.
-- Luanti says nothing about any of them: a node definition knows its drawtype,
-- its groups and whether it waves, and that is what there is to go on. So this
-- is a guess, and it is in a file of its own so that it can be argued with
-- without touching the world.
--
-- The numbers:
--   roughness      0 = mirror, 1 = chalk
--   spec_strength  how much light the surface returns at all
--   bumpiness      how much the texture's own luminance becomes relief
--   translucency   how much light comes through from behind
--   spots          animated sparkle: moving highlights, for water
--   static_spots   the same but standing still: facets in sand, snow, ore
--
-- The two spot fractions are how much of a surface is a spot at any one
-- moment, and they want to be small: a spot reflects at full strength
-- whatever the rest of the surface does, so a few per cent reads as a surface
-- catching the light and a tenth of it reads as glitter paint. These are
-- scaled to the numbers apps/sample_lighting_scene arrived at, which is the same
-- shader with the same constants behind it: grass 0.012, leaves 0.03, water
-- 0.05, rock 0.04 standing still.
--
-- Not here: metalness. The spec map's four channels are full and cMetallic is
-- per material, so metal nodes read as very glossy dielectrics.

local M = {}

-- Luanti's NodeDrawType; nodedef.lua has the whole list
local DRAWTYPE_LIQUID = 2
local DRAWTYPE_FLOWINGLIQUID = 3
local DRAWTYPE_GLASSLIKE = 4
local DRAWTYPE_ALLFACES = 5
local DRAWTYPE_ALLFACES_OPTIONAL = 6
local DRAWTYPE_PLANTLIKE = 9
local DRAWTYPE_FIRELIKE = 14
local DRAWTYPE_GLASSLIKE_FRAMED = 13
local DRAWTYPE_GLASSLIKE_FRAMED_OPTIONAL = 15
local DRAWTYPE_PLANTLIKE_ROOTED = 17

local NODEDEF_ALPHAMODE_BLEND = 0

-- The same drawtypes by the name a mod registers them under
local DRAWTYPE_BY_NAME = {
	normal = 0, airlike = 1, liquid = 2, flowingliquid = 3, glasslike = 4,
	allfaces = 5, allfaces_optional = 6, torchlike = 7, signlike = 8,
	plantlike = 9, fencelike = 10, raillike = 11, nodebox = 12,
	glasslike_framed = 13, firelike = 14, glasslike_framed_optional = 15,
	mesh = 16, plantlike_rooted = 17,
}

-- What everything is before anything is known about it: a painted texture with
-- a wide, weak highlight, which is what these textures are painted as
local DEFAULT = {
	roughness = 0.95,
	spec_strength = 0.2,
	bumpiness = 0.3,
	translucency = 0,
	spots = 0,
	static_spots = 0,
}

-- A name that says what a node is made of when its groups do not. Games whose
-- nodes carry no groups worth reading are common enough that this is worth the
-- dozen patterns; the groups win where there are any.
local BY_NAME = {
	{"water", {roughness = 0.35, spec_strength = 0.9, bumpiness = 0,
			spots = 0.05}},
	{"lava", {roughness = 0.6, spec_strength = 0.3, bumpiness = 0.2}},
	{"ice", {roughness = 0.10, spec_strength = 1.0, bumpiness = 0.1,
			static_spots = 0.05}},
	{"glass", {roughness = 0.10, spec_strength = 1.0, bumpiness = 0}},
	{"crystal", {roughness = 0.15, spec_strength = 0.9, bumpiness = 0.1,
			static_spots = 0.06}},
	{"gem", {roughness = 0.15, spec_strength = 0.9, static_spots = 0.06}},
	{"diamond", {roughness = 0.12, spec_strength = 1.0, static_spots = 0.07}},
	{"mese", {roughness = 0.2, spec_strength = 0.8, static_spots = 0.06}},
	{"metal", {roughness = 0.35, spec_strength = 0.8, bumpiness = 0.1}},
	{"steel", {roughness = 0.35, spec_strength = 0.8, bumpiness = 0.1}},
	{"copper", {roughness = 0.40, spec_strength = 0.7, bumpiness = 0.1}},
	{"bronze", {roughness = 0.40, spec_strength = 0.7, bumpiness = 0.1}},
	{"tin", {roughness = 0.35, spec_strength = 0.8, bumpiness = 0.1}},
	{"gold", {roughness = 0.30, spec_strength = 0.9, bumpiness = 0.1}},
	{"snow", {roughness = 0.85, spec_strength = 0.35, bumpiness = 0.2,
			static_spots = 0.06}},
	{"sand", {roughness = 1.0, spec_strength = 0.15, bumpiness = 0.6,
			static_spots = 0.04}},
	{"ore", {static_spots = 0.05, spec_strength = 0.5, roughness = 0.6}},
	-- Curated for VoxeLibre, whose names the patterns above miss
	-- ([VOXEL_MATERIALS] layer 3): what it is made of, by name, kept here
	-- and never in the game. Argued with from pictures, not from a
	-- table; the numbers are first cuts in the same scale as the rest.
	{"stone_with_", {static_spots = 0.05, spec_strength = 0.5,
			roughness = 0.6}},           -- its ores: coal, iron, redstone...
	{"obsidian", {roughness = 0.2, spec_strength = 0.8, bumpiness = 0.15}},
	{"quartz", {roughness = 0.35, spec_strength = 0.6, bumpiness = 0.1}},
	{"prismarine", {roughness = 0.4, spec_strength = 0.5, bumpiness = 0.2,
			static_spots = 0.04}},
	{"slime", {roughness = 0.3, spec_strength = 0.7, bumpiness = 0}},
	{"honey", {roughness = 0.3, spec_strength = 0.7, bumpiness = 0}},
	{"emerald", {roughness = 0.15, spec_strength = 0.9, static_spots = 0.06}},
	{"lapis", {roughness = 0.5, spec_strength = 0.4, bumpiness = 0.2}},
	{"wool", {roughness = 1.0, spec_strength = 0.05, bumpiness = 0.3}},
	{"carpet", {roughness = 1.0, spec_strength = 0.05, bumpiness = 0.3}},
	{"clay", {roughness = 0.95, spec_strength = 0.1, bumpiness = 0.2}},
	{"mud", {roughness = 0.6, spec_strength = 0.3, bumpiness = 0.4}},
}

local function copy(t)
	local out = {}
	for k, v in pairs(DEFAULT) do
		out[k] = v
	end
	for k, v in pairs(t or {}) do
		out[k] = v
	end
	return out
end

local function group(def, name)
	return (def.groups or {})[name] or 0
end

-- What a node's surface is: a table of the six numbers. def is what
-- nodedef.parse() returned.
function M.for_node(def)
	if not def then
		return copy(nil)
	end
	local drawtype = def.drawtype or 0
	if type(drawtype) == "string" then
		drawtype = DRAWTYPE_BY_NAME[drawtype] or 0
	end
	-- alpha_mode is the wire's; blend is what bootstrap.lua worked out
	-- from use_texture_alpha, the rule being its own
	local blend = def.alpha_mode == NODEDEF_ALPHAMODE_BLEND or
			def.blend == true
	local out

	if drawtype == DRAWTYPE_LIQUID or drawtype == DRAWTYPE_FLOWINGLIQUID then
		-- A liquid's highlights move because the liquid does; lava is the one
		-- that does not want them, and its name is what says so
		out = copy({roughness = 0.25, spec_strength = 0.9, bumpiness = 0,
				spots = 0.05})
	elseif drawtype == DRAWTYPE_PLANTLIKE or
			drawtype == DRAWTYPE_PLANTLIKE_ROOTED or
			drawtype == DRAWTYPE_ALLFACES or
			drawtype == DRAWTYPE_ALLFACES_OPTIONAL then
		-- Leaves and plants: lit from behind as much as from in front, which
		-- is the whole of what makes a canopy read as a canopy
		-- Rough and barely specular ([PBR_FIT] tuning, 2026-09-18): with
		-- a Cook-Torrance lobe in the light pass the canopy's cards at
		-- 0.8 / 0.25 read 0.72 of the render's saturation
		out = copy({roughness = 0.95, spec_strength = 0.12, bumpiness = 0.2,
				translucency = 0.12, spots = 0.03})
	elseif drawtype == DRAWTYPE_GLASSLIKE or
			drawtype == DRAWTYPE_GLASSLIKE_FRAMED or
			drawtype == DRAWTYPE_GLASSLIKE_FRAMED_OPTIONAL or blend then
		out = copy({roughness = 0.10, spec_strength = 1.0, bumpiness = 0,
				static_spots = 0.03})
	elseif group(def, "crumbly") > 0 then
		-- Dirt, sand, gravel: matte, and rough enough that the texture's own
		-- luminance is worth reading as relief
		out = copy({roughness = 1.0, spec_strength = 0.1, bumpiness = 0.7})
	elseif group(def, "cracky") > 0 then
		out = copy({roughness = 0.7, spec_strength = 0.4, bumpiness = 0.35})
	elseif group(def, "snappy") > 0 or group(def, "fleshy") > 0 then
		out = copy({roughness = 1.0, spec_strength = 0.05, bumpiness = 0.15})
	elseif group(def, "choppy") > 0 then
		-- Wood: a little sheen along the grain, and the grain itself
		out = copy({roughness = 0.85, spec_strength = 0.2, bumpiness = 0.4})
	else
		out = copy(nil)
	end

	-- A name that says what it is overrides what its drawtype guessed, because
	-- "stone with an ore in it" and "stone" are the same drawtype and the same
	-- group and are not the same surface. Liquids keep what the drawtype gave
	-- them apart from lava, which is why this runs after and not before.
	local name = def.name or ""
	for _, entry in ipairs(BY_NAME) do
		if string.find(name, entry[1], 1, true) then
			for k, v in pairs(entry[2]) do
				out[k] = v
			end
			break
		end
	end

	-- Something that gives off light is lit by itself and not by the sun, and
	-- a highlight crawling over a torch reads as a mistake
	if (def.light_source or 0) > 0 then
		out.spots = 0
		out.static_spots = 0
		out.spec_strength = math.min(out.spec_strength, 0.1)
	end

	-- What waves is moving, so its sparkle moves with it; what does not, does
	-- not. waving is 1 for plants and 2 for leaves.
	if (def.waving or 0) == 0 and out.spots > 0 and
			drawtype ~= DRAWTYPE_LIQUID and
			drawtype ~= DRAWTYPE_FLOWINGLIQUID then
		out.static_spots = math.max(out.static_spots, out.spots)
		out.spots = 0
	end

	-- Fire is drawn as light, not as a surface
	if drawtype == DRAWTYPE_FIRELIKE then
		out.spec_strength = 0
		out.spots = 0
		out.static_spots = 0
	end
	return out
end

-- What the guessing has to hold, checked at load: the cases the table above is
-- written for actually come out of it.
do
	local water = M.for_node({name = "default:water_source", drawtype = 2})
	assert(water.spots > 0 and water.roughness < 0.4, "surface: water")
	local leaves = M.for_node({name = "default:leaves", drawtype = 5,
			waving = 2, groups = {snappy = 3}})
	assert(leaves.translucency > 0.05, "surface: leaves")
	local dirt = M.for_node({name = "default:dirt", drawtype = 0,
			groups = {crumbly = 3}})
	assert(dirt.bumpiness > 0.5 and dirt.spec_strength < 0.2, "surface: dirt")
	local sand = M.for_node({name = "default:sand", drawtype = 0,
			groups = {crumbly = 3}})
	assert(sand.static_spots > 0, "surface: sand")
	local torch = M.for_node({name = "default:torch", drawtype = 7,
			light_source = 14})
	assert(torch.static_spots == 0 and torch.spots == 0, "surface: torch")
	local glass = M.for_node({name = "default:glass", drawtype = 4})
	assert(glass.roughness < 0.2 and glass.spec_strength > 0.9,
			"surface: glass")
	local plain = M.for_node(nil)
	assert(plain.roughness == 0.95 and plain.spots == 0, "surface: default")
	-- The curated VoxeLibre names land: an ore by its stone_with_ name,
	-- wool matte
	local ore = M.for_node({name = "mcl_core:stone_with_iron", drawtype = 0,
			groups = {cracky = 3}})
	assert(ore.static_spots > 0, "surface: VoxeLibre ore")
	local wool = M.for_node({name = "mcl_wool:red", drawtype = 0})
	assert(wool.spec_strength < 0.1, "surface: wool")
	-- The module's spelling comes out the same as the wire's
	local named = M.for_node({name = "default:water_source",
			drawtype = "liquid"})
	assert(named.spots == water.spots and named.roughness == water.roughness,
			"surface: drawtype by name")
	local pane = M.for_node({name = "xpanes:pane", drawtype = "nodebox",
			blend = true})
	assert(pane.roughness < 0.2, "surface: blend by flag")
end

return M
-- vim: set noet ts=4 sw=4:
