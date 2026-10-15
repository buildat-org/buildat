-- Buildat: extension/luanti_client/world.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- Luanti's mapblocks on screen: a scene with a camera in it, and a node per
-- block with buildat's voxel mesher on it.
--
-- A mapblock is 16^3 nodes. The mesher culls the faces of a chunk against the
-- voxels around it, so it wants a one-voxel border: a block becomes an 18^3
-- volume holding the block itself plus a slice off each of the six neighbours.
-- buildat.pack_voxel_volume() does all seven copies in one call. A neighbour
-- arriving makes this block's mesh out of date, which is what the dirty set is
-- for; a block with a neighbour still missing shows a seam until it comes.
--
-- Where the world sits: a buildat voxel and a Luanti node both occupy the cube
-- centred on their integer coordinate, so Luanti node coordinates are Urho3D
-- world coordinates one for one. block_node_position() is the same arithmetic
-- builtin/voxelworld does for its chunks.

local sounds_proto = buildat.run_extension_file("res/sounds.lua")
local shapes = buildat.run_extension_file("shapes.lua")
local particles = buildat.run_extension_file("res/particles.lua")
local light_flood = buildat.run_extension_file("light.lua")
local skyvis = buildat.run_extension_file("skyvis.lua")
local sky_model = buildat.run_extension_file("res/sky_model.lua")
local world_particles = buildat.run_extension_file("world_particles.lua")
local world_sounds = buildat.run_extension_file("world_sounds.lua")
local world_pointing = buildat.run_extension_file("world_pointing.lua")
local world_object_meshes =
		buildat.run_extension_file("world_object_meshes.lua")
-- BUILDAT_LUANTI_NO_SPOTS=1, the reference runs' switch: no sparkle on
-- any surface, since the path-traced reference draws none. The module's
-- bootstrap.lua honours the same variable.
local NO_SPOTS = (buildat.get_env("BUILDAT_LUANTI_NO_SPOTS") or "") ~= ""

local surface = buildat.run_extension_file("surface.lua")
-- The sky rendered into a cube for the world to reflect, shared with
-- apps/vanilla; see [SKY_REFLECTIONS]
local skycube = require("buildat/extension/skycube")

local M = {}

local BLOCKSIZE = 16
-- The volume handed to the mesher, block plus border
local VOLUME_MIN = -1
local VOLUME_MAX = BLOCKSIZE

-- buildat voxel ids, in the order they go into the registry
local VOXEL_AIR = 1
local VOXEL_PLACEHOLDER = 2

-- Luanti's fixed content ids; see mapnode.h
local CONTENT_AIR = 126
local CONTENT_IGNORE = 127

-- Luanti draw types drawn as a full cube from the node's own six tiles.
--
-- A draw type that has a shape of its own -- a node box, a mesh, a flowing
-- liquid -- is here too: what it gets from this table is only what its cube
-- is when it has no shape to be drawn as, which is what a mesh in a format
-- this cannot read and a liquid at its top level come to.
--
-- The value is the buildat edge material the cube gets, which is what decides
-- when a face between two of them is drawn: two "ground" cubes hide the face
-- between them, two glass cubes hide the face between each other but not the
-- one against ground.
--
-- Leaves (NDT_ALLFACES) are "allfaces": a cube whose every face is drawn,
-- including the ones between two of them, because the texture is full of
-- holes and what is behind a hole is the next leaf's face. The shader
-- discards the holes.
--
-- A liquid is "liquid": it hides the face between two of itself, draws the
-- face against everything else -- including the stone it sits in, which is
-- visible through it -- and its faces are blended rather than cut out.
local EDGEMATERIAL_GLASS = 10
local EDGEMATERIAL_LIQUID = 11
local CUBE_DRAWTYPES = {
	[0] = "ground",  -- NDT_NORMAL
	[2] = "liquid",  -- NDT_LIQUID
	[3] = "liquid",  -- NDT_FLOWINGLIQUID
	[4] = "glass",   -- NDT_GLASSLIKE
	[5] = "allfaces",-- NDT_ALLFACES, leaves
	[6] = "allfaces",-- NDT_ALLFACES_OPTIONAL
	[13] = "glass",  -- NDT_GLASSLIKE_FRAMED
	[15] = "glass",  -- NDT_GLASSLIKE_FRAMED_OPTIONAL
	[16] = "ground", -- NDT_MESH, drawn as its selection box; see shapes.lua
}
local DRAWTYPE_AIRLIKE = 1
local DRAWTYPE_FLOWINGLIQUID = 3
local DRAWTYPE_RAILLIKE = 11
-- nodedef.lua's M.LIQUID_NONE, which is what a node that is not a liquid has
local NODEDEF_LIQUID_NONE = 0
-- nodedef.lua's M.ALPHAMODE_BLEND: the game asked for this node's texture
-- alpha to be blended rather than used as a mask
local NODEDEF_ALPHAMODE_BLEND = 0

-- How long a frame may spend handing blocks to the mesher, and how many it
-- may hand over however fast they go. Meshing itself is on a worker thread,
-- but packing the volume and handing it over is not, so a burst of a hundred
-- blocks arriving at once would otherwise be one long frame. One block is
-- always meshed, so a block that costs more than the whole budget still gets
-- drawn.
local MESH_BUDGET_US = 4000
local MESH_PER_FRAME = 8

-- What the mesher is told each node id is. Only air is known without the node
-- definitions, so everything else is the placeholder cube; CONTENT_IGNORE is
-- "no data here", which draws as nothing.
local PLACEHOLDER_MAP = {
	[CONTENT_AIR] = VOXEL_AIR,
	[CONTENT_IGNORE] = VOXEL_AIR,
}

-- Luanti keeps two light values in param1: the low nibble is the light a node
-- has when the sun is up, the high one the light it gets from light sources
-- alone. What the sun itself contributes is the difference, which is what
-- buildat calls skylight; the high nibble is buildat's lamplight.
--
-- Both of buildat's nibbles are written by one source with field = "light",
-- so a block's light costs one pass over its param1 rather than two. The map
-- is a byte per param1 value, which is what pack_voxel_volume takes.
local LIGHT_MAP = (function()
	local out = {}
	for p = 0, 255 do
		local day = p % 16
		local night = math.floor(p / 16)
		local sky = day > night and day - night or 0
		out[p + 1] = string.char(night * 16 + sky)
	end
	return table.concat(out)
end)()

-- The same, for the PBR path, whose skylight means something else.
--
-- There the sun is a real light with a shadow map, and the shadow map is what
-- darkens what is under a tree. So node lighting is left to answer the one
-- question a shadow map cannot -- "am I underground" -- and nothing else: the
-- curve holds at full until the light has fallen far enough that it can only
-- be rock overhead, and then drops away. A canopy reads 11..14 and stays fully
-- lit; a cave reads 0..2 and goes dark; a doorway is the band between.
--
-- The knee is the tuning knob. Lower it and cave mouths brighten; raise it and
-- overhangs start being darkened twice, once here and once by the shadow map.
local PBR_SKY_KNEE_LOW = 2
local PBR_SKY_KNEE_HIGH = 11

local PBR_LIGHT_MAP = (function()
	local out = {}
	for p = 0, 255 do
		local day = p % 16
		local night = math.floor(p / 16)
		local sky = day > night and day - night or 0
		local t = (sky - PBR_SKY_KNEE_LOW) /
				(PBR_SKY_KNEE_HIGH - PBR_SKY_KNEE_LOW)
		t = t < 0 and 0 or (t > 1 and 1 or t)
		local smooth = t * t * (3 - 2 * t)
		out[p + 1] = string.char(night * 16 + math.floor(15 * smooth + 0.5))
	end
	return table.concat(out)
end)()

-- What the curve has to hold, checked at load: full sun outdoors, nothing in
-- rock, and a canopy left for the shadow map to darken. The lamp nibble rides
-- through untouched, because the two are separate lights.
do
	local function sky_of(day, night)
		return string.byte(PBR_LIGHT_MAP, night * 16 + day + 1) % 16
	end
	local function lamp_of(day, night)
		return math.floor(string.byte(PBR_LIGHT_MAP, night * 16 + day + 1) / 16)
	end
	assert(sky_of(15, 0) == 15, "pbr light curve: open sky")
	assert(sky_of(PBR_SKY_KNEE_HIGH, 0) == 15, "pbr light curve: canopy")
	assert(sky_of(PBR_SKY_KNEE_LOW, 0) == 0, "pbr light curve: rock")
	assert(sky_of(0, 0) == 0, "pbr light curve: dark")
	assert(sky_of(8, 8) == 0, "pbr light curve: lamp is not sky")
	assert(lamp_of(15, 7) == 7, "pbr light curve: lamp nibble kept")
end

-- What the volume is before the block and its neighbours are copied into it:
-- air that sees the full sky. A face against a neighbour that has not arrived
-- is then lit as if it were out in the open, which is wrong in a cave but
-- only until the neighbour comes, and a wrongly lit face reads better than
-- the black one that unlit air would give. This is a raw voxel word under
-- the format base_registry() sets, where the skylight is bits 16..19.
local VOXEL_AIR_LIT = VOXEL_AIR + 15 * 0x10000

-- How a (voxel id, param2) pair is keyed: id + param2 * this, which is what
-- pack_voxel_volume's paired lookup wants. Luanti's ids are 16 bits.
local PAIR_SCALE = 65536

-- Luanti's ContentParamType2, the values that change what a voxel looks like
local CPT2_FACEDIR = 3
local CPT2_WALLMOUNTED = 4
local CPT2_COLOR = 8
local CPT2_COLORED_FACEDIR = 9
local CPT2_COLORED_WALLMOUNTED = 10
local CPT2_COLORED_DEGROTATE = 12
local CPT2_4DIR = 13
local CPT2_COLORED_4DIR = 14

-- How param2 says which way a voxel faces, per paramtype2: which mask of it
-- to read, and what the value means
local FACING = {
	[CPT2_FACEDIR] = "facedir",
	[CPT2_COLORED_FACEDIR] = "facedir",
	[CPT2_4DIR] = "4dir",
	[CPT2_COLORED_4DIR] = "4dir",
	[CPT2_WALLMOUNTED] = "wallmounted",
	[CPT2_COLORED_WALLMOUNTED] = "wallmounted",
}

-- Which bits of param2 are the palette index, per paramtype2. Luanti indexes
-- the 256-entry palette with the whole of param2 for CPT2_COLOR and with the
-- high bits for the types that keep a direction in the low ones; what is
-- written here is how much of param2 one colour covers, which is what the low
-- bits are worth: param2 - param2 % step is the index.
local COLOR_STEP = {
	[CPT2_COLOR] = 1,
	[CPT2_COLORED_FACEDIR] = 32,
	[CPT2_COLORED_WALLMOUNTED] = 8,
	[CPT2_COLORED_DEGROTATE] = 32,
	[CPT2_COLORED_4DIR] = 4,
}

-- Lights in the scene, for the voxels a game says give light. Luanti floods
-- light through the voxels and bakes it into param1; this puts a real light
-- where the torch is instead, which is a buildat-ism and looks like one --
-- the light falls off around corners the way a light does.
--
-- There is a cap because a forward renderer draws the geometry again per
-- light: the nearest few to the camera are lit and the rest of the world
-- keeps the light its param1 gives it.
local MAX_SCENE_LIGHTS = 24
-- Per block, so that a room full of lamps cannot fill the list on its own
local MAX_LIGHTS_PER_BLOCK = 12
-- How far a light of level n reaches, in voxels. Luanti's own light falls off
-- one level per voxel, so the level is the range; a little more looks better
-- than a little less.
local LIGHT_RANGE_PER_LEVEL = 1.0
-- What a light source is coloured. A game does not say -- Luanti's
-- light_source is one number -- and what gives light in one is mostly fire.
local LIGHT_COLOR = {r = 1.0, g = 0.85, b = 0.65}

-- A voxel's collision boxes, turned the way its facedir says
local function turn_boxes(boxes, facedir)
	local out = {}
	for i, box in ipairs(boxes) do
		out[i] = shapes.turn_box(box, facedir)
	end
	return out
end

-- What a definition's param2 does to how its voxels are drawn, as the
-- variants buildat's mesher indexes by the param: a shape turned one way,
-- a cube's tiles moved to the faces they end up on, a liquid's surface at
-- one of eight levels. One variant per distinct look, claiming the param2
-- values that come to it -- so a facedir is twenty-four of them rather
-- than two hundred and fifty-six, and none of them is a voxel type.
--
-- A param2 that comes to nothing different is left unclaimed and draws as
-- the definition itself does, which is facing 0 with a full liquid.
--
-- The palette is not here: a palette entry tints the *texture*, and a
-- variant's colour tints the light, so a colour still gets a voxel of its
-- own with its own composed textures. See build_pair().
local function build_variants(def, facing, liquid_range, mesh_quads)
	if not facing and not liquid_range then
		return nil
	end
	local list = {}
	local by_key = {}
	for p2 = 0, 255 do
		local facedir = shapes.facedir_of(facing, p2)
		-- A wallmounted shape wants the direction itself, not only the
		-- facedir it comes to: which of its three boxes it is made of
		-- depends on it
		local wall = facing == "wallmounted" and p2 % 8 or nil
		-- A liquid at the top level is a whole cube, which the voxel
		-- itself already is
		local ltop = liquid_range and
				shapes.liquid_top(liquid_range, p2) or nil
		if ltop and ltop >= 0.5 then
			ltop = nil
		end
		if (facedir and facedir ~= 0) or ltop then
			local key = tostring(facedir).."/"..tostring(wall).."/"..
					tostring(ltop)
			local var = by_key[key]
			if not var then
				var = {params = {}}
				local shape = shapes.for_node(def, facedir, wall,
						mesh_quads, ltop)
				if shape then
					var.shape = shape
				elseif facedir and facedir ~= 0 then
					-- A cube wears the same six textures in the order
					-- the turn puts them in, each turned inside its own
					-- face. The faces are 0...5 here and 1...6 there.
					local tiles = shapes.FACEDIR_TILES[facedir + 1]
					if tiles then
						local order = {}
						for i = 1, 6 do
							order[i] = (tiles[i] or i) - 1
						end
						var.tile_order = order
						var.tile_turns =
								shapes.FACEDIR_TILE_TURNS[facedir + 1]
					end
				end
				if ltop then
					var.liquid_top = ltop
				end
				by_key[key] = var
				list[#list + 1] = var
			end
			var.params[#var.params + 1] = p2
		end
	end
	if #list == 0 then
		return nil
	end
	return list
end

local function block_key(x, y, z)
	return x..","..y..","..z
end

-- The six directions a border slice comes from, and which slice of the
-- neighbour it is: for -x, the neighbour's x = 15 plane lands at x = -1.
local NEIGHBOURS = {
	{-1, 0, 0}, {1, 0, 0},
	{0, -1, 0}, {0, 1, 0},
	{0, 0, -1}, {0, 0, 1},
}

-- new(magic, buildat, log, options)
--
-- magic is the sandboxed Urho3D interface and buildat the sandboxed buildat
-- interface (buildat.safe), because set_voxel_geometry() wants sandboxed nodes
-- and this is called from an extension, where buildat is the unsafe table.
--
-- options.far_clip, options.texture: what the camera sees and what an unknown
-- node looks like.
function M.new(magic, buildat, log, options)
	options = options or {}
	local far_clip = options.far_clip or 240
	local texture = options.texture or "luanti_client/res/placeholder.png"
	-- options.read_mesh(def) -> the quads of the model a "mesh" drawtype
	-- names, or nil for one that could not be read. Whoever has the media
	-- has the file; this only wants the quads.
	local read_mesh = options.read_mesh
	-- options.read_image(resource) -> w, h, rgba, for the colour a light
	-- source shines in. Handed in rather than taken from buildat because it
	-- is not part of the sandbox's own interface.
	local read_image = options.read_image
	-- options.media_texture(name) -> the resource name of one of the game's
	-- own textures, or nil for one that has not arrived. The sky's sun and
	-- moon are the ones here that want it, and their names can be texture
	-- expressions like any other.
	local media_texture = options.media_texture
	-- Which of the three rendering modes the world is drawn in, fixed for the
	-- session: the atlas's surface maps have to be on from the first texture
	-- it builds, and they are two thirds of what adding one costs.
	--
	--   unlit    the baked light and nothing else, which is official Luanti
	--            with its dynamic shadows off
	--   shadows  the same with the sun's shadow map multiplying it, which is
	--            official Luanti as it is usually played
	--   pbr      res/PBRVoxel: normal and surface maps, reflections of the
	--            sky, the sun as a real light. A deliberate deviation.
	--
	-- See [RENDER_MODES] in doc/plan/rendering_plan.md. `pbr` stays a boolean
	-- beside it because everything below that asks about surface maps, sky
	-- visibility or the light curve is asking about that mode alone.
	local mode = options.mode or "unlit"
	local pbr = mode == "pbr"

	local self = {}
	self.mode = mode
	self.pbr = pbr

	-- One of the game's own textures, drawn without smoothing. A Luanti
	-- game's textures are pixel art and interpolating them is wrong at every
	-- size: the voxel atlas already says so in the engine (see
	-- SetFilterMode in src/impl/atlas.cpp) and everything else a game's
	-- texture goes on -- an object, a dropped item, the sun -- wants the
	-- same. The mode is on the texture rather than on the material, so
	-- setting it once per use is setting it for good; it is cheap and there
	-- is nowhere better.
	-- filter is FILTER_NEAREST unless the caller says otherwise: a game's
	-- textures are pixel art and interpolating them is wrong at every size.
	-- The exception is a particle, which is drawn smaller than its own
	-- texture and whose whole shape can be one pixel wide -- a rain drop is
	-- -- so point sampling drops it altogether at a distance. Luanti's own
	-- particle material says nearest magnification and *mipmapped*
	-- minification, which is FILTER_NEAREST_ANISOTROPIC here: crisp up
	-- close, and a thin thing that is far away goes dim rather than
	-- disappearing.
	--
	-- The filter belongs to the texture rather than to the material, so a
	-- file used both ways gets whichever was asked for last. Nothing in the
	-- games looked at does that.
	local function game_texture(name, filter)
		local tex = magic.cache:GetResource("Texture2D", name)
		if tex then
			tex.filterMode = filter or magic.FILTER_NEAREST
		end
		return tex
	end

	-- The colour of full sunlight for a day/night factor of 0...1, which is
	-- Luanti's own get_sunlight_color(): a little blue is left at night and a
	-- little is added in the day, so a shadowed face reads cool rather than
	-- grey.
	local function sunlight_color(factor)
		local rg = factor - 0.04
		if rg < 0 then
			rg = 0
		end
		return magic.Color(rg, rg, 0.98 * factor + 0.078)
	end

	local scene = magic.Scene()
	scene:CreateComponent("Octree")
	self.scene = scene

	-- How wide the sun and the moon are drawn, on a plane one unit along
	-- their direction, at the scale of one: the ratio Luanti draws them at.
	-- A game's own scale multiplies these.
	local SUN_HALF = 0.075
	local MOON_HALF = sky_model.MOON_HALF
	-- How many stars a game asks for by default, and the share of the star
	-- grid's cells that hold one at that count
	local STARS_DEFAULT = sky_model.STARS_DEFAULT
	local STAR_DENSITY_DEFAULT = sky_model.STAR_DENSITY_DEFAULT
	-- Luanti's own cloud speed, density and alpha, and a speed in the sky
	-- shader's units: res/sky_model.lua's, vanilla's as well
	local CLOUD_SPEED_DEFAULT = sky_model.CLOUD_SPEED_DEFAULT
	local CLOUD_WIND_PER_NODE = sky_model.CLOUD_WIND_PER_NODE
	local CLOUD_DENSITY_DEFAULT = sky_model.CLOUD_DENSITY_DEFAULT
	local CLOUD_ALPHA_DEFAULT = sky_model.CLOUD_ALPHA_DEFAULT

	-- What the game says is in the sky, out of SET_SUN, SET_MOON, SET_STARS
	-- and CLOUD_PARAMS. What is here to begin with is what Luanti has before
	-- a game says anything.
	--
	-- The sun and the moon wear the textures the game gives them, on the
	-- shader's two texture units.
	--
	-- simplified: the sunrise texture, the tonemaps and the stars' own colour
	-- ramp are not drawn -- a tonemap is a colour grade of the body and the
	-- sunrise is a band of its own along the horizon, which the shader paints
	-- from the sky colours instead. What is honoured is the textures, whether
	-- each body is there at all, how big, how many, and what colour the
	-- stars and the clouds are, which is what turns a dimension with no sky
	-- into one.
	local sky_bodies = {
		sun = {visible = true, scale = 1},
		moon = {visible = true, scale = 1},
		stars = {visible = true, count = STARS_DEFAULT, scale = 1},
		clouds = {density = CLOUD_DENSITY_DEFAULT,
				speed = CLOUD_SPEED_DEFAULT},
	}

	-- What the sky looks like until the server says, and what it says; see
	-- set_sky() below
	local FOG = {r = 0.60, g = 0.72, b = 0.88}
	local sky = nil
	local daylight = 1.0
	-- Where the sun was put last, so that a SET_SKY in the middle of the
	-- night does not draw it back at noon
	local daylight_time = nil

	-- The sky itself: a skybox drawn by res/SkyDome.glsl,
	-- which is handed the colours and the sun's direction from here.
	local sky_node = scene:CreateChild("Sky")
	local sky_material = nil
	do
		local skybox = sky_node:CreateComponent("Skybox")
		skybox:SetModel(magic.cache:GetResource("Model", "Models/Box.mdl"))
		sky_material = magic.Material.new()
		sky_material:SetTechnique(0, magic.cache:GetResource("Technique",
				"shaders/res/SkyDome.xml"))
		skybox.material = sky_material
	end

	local zone_node = scene:CreateChild("Zone")
	local zone = zone_node:CreateComponent("Zone")
	zone.boundingBox = magic.BoundingBox(-100000, 100000)
	zone.ambientColor = sunlight_color(1.0)
	zone.fogColor = magic.Color(FOG.r, FOG.g, FOG.b)
	zone.fogStart = far_clip * 0.7
	zone.fogEnd = far_clip
	zone.priority = -1000

	-- No light in the scene: the mesher bakes the light into the vertex
	-- colours and VoxelUnlit reads it from there, so there is nothing for a
	-- directional light to reach. The PBR path reads the same vertex colours
	-- as its ambient, so that is true of it as well -- what it adds on top is
	-- the sky it reflects.
	-- shadows differs from unlit in one file: LuantiVoxelUnlit adds a light
	-- pass that multiplies by the shadow factor and writes nothing else.
	-- Water is shadowed on the shadows path as the module's is, through
	-- LuantiVoxelUnlitAlpha's multiplied light pass ([PARITY_LEFTOVERS]);
	-- unlit's VoxelUnlitAlpha has no light pass.
	local opaque_name = "luanti_client/res/VoxelUnlit.xml"
	local alpha_name = "luanti_client/res/VoxelUnlitAlpha.xml"
	if pbr then
		opaque_name = "luanti_client/res/PBRVoxel.xml"
		alpha_name = "luanti_client/res/PBRVoxelAlpha.xml"
	elseif mode == "shadows" then
		opaque_name = "luanti_client/res/LuantiVoxelUnlit.xml"
		alpha_name = "luanti_client/res/LuantiVoxelUnlitAlpha.xml"
	end
	local technique = magic.cache:GetResource("Technique", opaque_name)
	local alpha_technique = magic.cache:GetResource("Technique", alpha_name)
	local sky_cube = nil
	if pbr then
		-- What the reflections are of: the sky as it is drawn, rendered
		-- into a cube of its own from the same material, and re-rendered
		-- when the hour moves it -- the sun, the moon and dawn where they
		-- are. The shader still multiplies it by the colour the sky is now
		-- (set_sky_tint below, cSkyColor in res/PBRVoxel.glsl), which is
		-- what being under water follows.
		sky_cube = skycube.new(magic, sky_material)
		zone.zoneTexture = sky_cube.texture
	end

	-- The sun, on the PBR path only. The vanilla path has no light in the
	-- scene at all: the mesher bakes what a node is lit by into the vertex
	-- colours, and a directional light on top of that would light everything
	-- twice. The PBR path keeps the vertex colours as its ambient and adds
	-- the sun, and what stops the double is the light curve: PBR_LIGHT_MAP
	-- reads as "am I underground" and nothing else, and the shader gates the
	-- sun by it. A leaf canopy is then darkened by the shadow map, which is
	-- the thing a shadow map is good at and a baked light value is not.
	--
	-- Biased for performance, because there are no graphics settings beyond
	-- the PBR checkbox: two cascades rather than four, a small map, and the
	-- single-tap filter.
	local SHADOW_NEAR = 24    -- nodes; the first cascade
	local SHADOW_FAR = 96     -- and the second, which is the shadow distance
	-- What a lit face gets from the sun, against the sky as the ambient.
	-- res/PBRVoxel's light pass is albedo * E * n.l / pi. The metered
	-- exposure takes the absolute level; this is the sun against the sky
	-- ([LUANTI_PBR_EXPOSURE], 2026-10-05: 50 was for Urho's own chain,
	-- which divided by pi twice).
	local SUN_BRIGHTNESS = 3.0
	-- What the sun's disc is drawn at, in the same units: well past white, so
	-- that the tone curve leaves it white and the bloom finds it
	local SUN_DISC_OVEREXPOSURE = 6.0

	-- What the moon is worth, in the same units. Not a measurement of
	-- anything -- real moonlight is a millionth of sunlight and would render
	-- as nothing -- but a night lit from where the moon is, coldly, and far
	-- enough above the sky's own light that the moon casts a shadow.
	local MOON_BRIGHTNESS = 1.0
	local MOON_COLOR = {0.55, 0.68, 1.0}

	-- When the sun and the moon are up, where the sun is and when its light
	-- goes red: res/sky_model.lua, one copy with vanilla's ([LUANTI_SHARED])
	local sun_amount, moon_amount = sky_model.sun_amount, sky_model.moon_amount
	local above_horizon, low_sun = sky_model.above_horizon, sky_model.low_sun
	local stepped_time = sky_model.stepped_time
	local sun_direction = sky_model.sun_direction

	local function clamp01(v)
		return v < 0 and 0 or (v > 1 and 1 or v)
	end

	local function luminance(rgb)
		return 0.2126 * rgb[1] + 0.7152 * rgb[2] + 0.0722 * rgb[3]
	end


	-- **The pbr path's light model is vanilla's** ([LC_PBR_PARITY]): the
	-- sun, the sky, the moon and the clouds out of res/sky_model.lua's PHYS,
	-- the path-traced reference's units. This client's are those over
	-- PHYS.lamp: its mesher bakes a lamp at full as one in the vertex colour,
	-- where vanilla's lamp is PHYS.lamp, so a torch-lit room keeps its place
	-- against the day. SUN_BRIGHTNESS and MOON_BRIGHTNESS above are what the
	-- lights start at; the shadows mode reads neither.
	local PHYS = sky_model.PHYS
	local UNITS = 1 / PHYS.lamp
	-- And no mesher's constant bounce, which was the whole of the light
	-- in a sealed cave on this path: its 0.055 lit the cave eleven times
	-- vanilla's, and a vertex colour is a byte, so vanilla's floor in
	-- these units (0.00125) rounds to nought there. The floor is the
	-- shader's CaveAmbient instead, set with the sky visibility below
	-- ([CAVE_EXPOSURE_FLOOR]).
	-- And the mesh's alpha in two nibbles, the sky and the shade, so the
	-- floor keeps a cave's corners where sky times shade is nought
	if pbr then
		buildat.set_mesh_bounce(0, 0, 0)
		buildat.set_mesh_alpha_nibbles(true)
	end
	-- The render's moon, a 4100 K lamp; the cold blue is the other modes'
	local PBR_MOON_COLOR = magic.Color(1.0, 0.86, 0.70)

	-- The sky of the hour in those units, out of the band's colours, which
	-- are display sRGB: Luanti's hue at the reference's radiance, the zenith
	-- and the horizon on their own curves (vanilla's apply_sky_of_hour), and
	-- the ambient the dome's mean, five parts zenith to one horizon -- what
	-- a face lit by the sky alone receives, which the shader multiplies by
	-- how much sky the face sees. height is the sine of the sun's elevation.
	-- simplified: none of vanilla's dawn glow, bounce or ground terms; the
	-- plain path's shader takes none of them.
	local function physical_sky(top, horizon, height)
		local function at(c, radiance)
			local r, g, b = c.r ^ 2.2, c.g ^ 2.2, c.b ^ 2.2
			local lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
			if lum <= 1e-6 then
				return magic.Color(radiance, radiance, radiance)
			end
			local k = radiance / lum
			return magic.Color(r * k, g * k, b * k)
		end
		local f = PHYS.sky(height)
		local z = at(top, UNITS * (PHYS.night_sky +
				(PHYS.sky_zenith - PHYS.night_sky) * f))
		local h = at(horizon, UNITS * (PHYS.night_sky +
				(PHYS.sky_horizon - PHYS.night_sky) * PHYS.horizon(height)))
		local dome = {r = (5 * z.r + h.r) / 6, g = (5 * z.g + h.g) / 6,
				b = (5 * z.b + h.b) / 6}
		local lum = 0.2126 * dome.r + 0.7152 * dome.g + 0.0722 * dome.b
		local k = UNITS * (PHYS.night_sky +
				(PHYS.sky_zenith * PHYS.dome - PHYS.night_sky) * f) /
				math.max(lum, 1e-9)
		return z, h, magic.Color(dome.r * k, dome.g * k, dome.b * k)
	end
	do
		local blue = magic.Color(0.38, 0.71, 0.96)
		local _, _, noon = physical_sky(blue, blue, 1)
		local _, _, night = physical_sky(blue, blue, -0.5)
		assert(math.abs(0.2126 * noon.r + 0.7152 * noon.g + 0.0722 * noon.b -
				UNITS * PHYS.sky_zenith * PHYS.dome) < 1e-6,
				"noon's ambient is the dome's radiance")
		assert(night.b < noon.b * 1e-3, "and the night's is the floor")
	end
	local sun_node = nil
	local sun_light = nil
	local moon_node = nil
	local moon_light = nil
	-- In shadows they are here for the shadow map alone: the technique's
	-- light pass multiplies by the shadow factor and never reads the light's
	-- colour or brightness. In unlit there is nothing to cast one from.
	if mode ~= "unlit" then
		sun_node = scene:CreateChild("Sun")
		sun_light = sun_node:CreateComponent("Light")
		sun_light.lightType = magic.LIGHT_DIRECTIONAL
		sun_light.castShadows = true
		sun_light.brightness = SUN_BRIGHTNESS
		sun_light.specularIntensity = 1.0
		-- Voxel faces at a grazing sun angle are the classic shadow acne
		-- case: a whole flat face falls inside one shadow texel and shadows
		-- itself in stripes. A slope-scaled bias on top of the automatic one,
		-- and a normal offset, which is the one that works on a face that is
		-- flat and wide.
		sun_light.shadowBias = magic.BiasParameters(0.00005, 0.8, 0.002)
		sun_light.shadowCascade = magic.CascadeParameters(
				SHADOW_NEAR, SHADOW_FAR, 0, 0, 0.8)
		-- The moon, which is the same light from the other side of the sky,
		-- with the same shadow map settings. The two are both in the scene
		-- for the hour either side of dusk and dawn, which is two shadow maps
		-- for that hour and one for the rest of the day.
		moon_node = scene:CreateChild("Moon")
		moon_light = moon_node:CreateComponent("Light")
		moon_light.lightType = magic.LIGHT_DIRECTIONAL
		moon_light.castShadows = true
		moon_light.brightness = MOON_BRIGHTNESS
		moon_light.specularIntensity = 1.0
		moon_light.shadowBias = magic.BiasParameters(0.00005, 0.8, 0.002)
		moon_light.shadowCascade = magic.CascadeParameters(
				SHADOW_NEAR, SHADOW_FAR, 0, 0, 0.8)
		moon_light.color = magic.Color(MOON_COLOR[1], MOON_COLOR[2],
				MOON_COLOR[3])

		-- Past the far cascade the world is ambient-lit, which at that range
		-- reads as haze rather than as a missing shadow
		magic.renderer.shadowMapSize = 1024
		magic.renderer.shadowQuality = magic.SHADOWQUALITY_SIMPLE_16BIT
		magic.renderer.drawShadows = true
	end

	-- The mesher sets no technique on skylit geometry -- only the game knows
	-- which shader reads what it packed -- so every block's materials get
	-- this one once they exist.
	local function apply_to(cg, tech)
		if not cg then
			return
		end
		-- Urho3D's drawables cast no shadow unless told to, one by one. On
		-- the vanilla path there is no light to cast one from; on the PBR
		-- path this is what puts the world in the sun's shadow map.
		cg.castShadows = mode ~= "unlit"
		local i = 0
		while true do
			local m = cg:GetMaterial(i)
			if m == nil then
				break
			end
			m:SetTechnique(0, tech)
			i = i + 1
		end
	end

	local function apply_technique(node)
		apply_to(node:GetComponent("CustomGeometry"), technique)
		-- The mesher puts the translucent voxels' faces on a child node of
		-- the chunk when there are any; those get the blended technique.
		local alpha_node = node:GetChild("alpha")
		if alpha_node then
			apply_to(alpha_node:GetComponent("CustomGeometry"),
					alpha_technique)
		end
	end

	local camera_node = scene:CreateChild("Camera")
	local camera = camera_node:CreateComponent("Camera")
	camera.nearClip = 0.1
	camera.farClip = far_clip
	-- What the field of view is when the server has not asked for anything
	-- else. TOCLIENT_FOV can ask for degrees or for a multiplier of this,
	-- over a transition time, which is what a game zooms with.
	local BASE_FOV = 72
	-- **The fov wanted, and the camera's** (user, 2026-09-30): the degrees
	-- are of the screen's short side, a portrait phone's width, which
	-- fov_for turns into the camera's vertical fov; set again each frame so
	-- that a turned screen follows. Transitions run on the wanted one.
	-- On self: this function is at Lua's 200 locals
	self.fov_for = require("buildat/core/urho3d").fov_for
	function self.apply_fov(v)
		self.fov_now = v
		camera.fov = self.fov_for(v)
	end
	self.apply_fov(BASE_FOV)
	self.camera_node = camera_node
	self.camera = camera

	local fov_target = BASE_FOV
	-- Degrees a second while a transition is running, and nil when there is
	-- none
	local fov_step = nil

	-- set_fov(fov, is_multiplier, transition_time), out of TOCLIENT_FOV. A
	-- fov of zero means back to the client's own.
	-- Zoom ([VIEW_KEYS]): official's zoom_fov, 15 degrees, while held;
	-- the server's last fov is kept on self (the function is at the
	-- 200-local line) so a zoom's end goes back to it
	function self:set_zoom(on, zoom_fov)
		if on then
			fov_step = nil
			self.apply_fov(zoom_fov or 15)
		else
			local f = self.fov_server or {}
			self:set_fov(f.fov, f.is_multiplier, 0)
		end
	end

	-- Fog off ([VIEW_KEYS]'s F3): the fog pushed past the far clip
	function self:set_fog(on)
		if not on then
			zone.fogStart = far_clip * 10
			zone.fogEnd = far_clip * 10 + 1
		else
			zone.fogStart = far_clip * 0.7
			zone.fogEnd = far_clip
		end
	end

	-- The view range from the pause menu ([LUANTI_PAUSE]); the fog keeps
	-- its share of it, on or off
	function self:set_far_clip(n)
		zone.fogStart = zone.fogStart * n / far_clip
		zone.fogEnd = zone.fogEnd * n / far_clip
		far_clip = n
		camera.farClip = n
	end

	function self:set_fov(fov, is_multiplier, transition_time)
		self.fov_server = {fov = fov, is_multiplier = is_multiplier}
		local want = BASE_FOV
		if fov and fov > 0 then
			want = is_multiplier and BASE_FOV * fov or fov
		end
		-- A game that asks for something absurd gets the nearest sane thing
		want = math.min(math.max(want, 5), 160)
		fov_target = want
		if transition_time and transition_time > 0 then
			fov_step = math.abs(want - self.fov_now) / transition_time
		else
			fov_step = nil
			self.apply_fov(want)
		end
	end

	function self:update_fov(dtime)
		if not fov_step then
			self.apply_fov(self.fov_now)
			return
		end
		local at = self.fov_now
		if at < fov_target then
			at = math.min(fov_target, at + fov_step * dtime)
		else
			at = math.max(fov_target, at - fov_step * dtime)
		end
		self.apply_fov(at)
		if at == fov_target then
			fov_step = nil
		end
	end

	-- Held on self: the renderer keeps a raw reference to the viewport, so a
	-- viewport that only a local pointed at gets freed under it the next time
	-- Lua collects garbage
	local viewport = magic.Viewport:new(scene, camera)
	self.viewport = viewport
	magic.set_preferred_viewports({viewport})

	-- On the PBR path the frame is rendered in HDR and tone mapped, the way
	-- apps/sample_lighting_scene does it. Nothing else makes the sun read as the
	-- sun: in a frame that clips at one, a sun strong enough to put a real
	-- shadow on the ground flattens every lit surface to white, and one weak
	-- enough not to do that is a sun whose colour and whose shadow are both
	-- invisible under the sky's. With the curve in, the sun can be fifty
	-- times the sky, which is about what it is, and what a lit surface gets
	-- is the sun's own colour rather than a mixture with the sky's; the same
	-- curve lifts the shadows, so a shadow under full skylight reads as shade
	-- rather than as a hole.
	if pbr then
		magic.renderer.HDRRendering = true
		local rp = viewport.renderPath:Clone()
		-- Vanilla's chain, vanilla being the reference ([LC_PBR_PARITY]):
		-- the exposure metered before the bloom, the bloom a glow on what
		-- clips, Uncharted2 with no bias on top of the meter. See
		-- builtin/luanti/client_lua/client.lua for where each number
		-- was picked.
		rp:Append(magic.cache:GetResource("XMLFile",
				"shaders/res/AutoExposureMean.xml"))
		rp:Append(magic.cache:GetResource("XMLFile",
				"PostProcess/BloomHDR.xml"))
		rp:Append(magic.cache:GetResource("XMLFile",
				"PostProcess/Tonemap.xml"))
		rp:Append(magic.cache:GetResource("XMLFile",
				"PostProcess/GammaCorrection.xml"))
		rp:SetEnabled("TonemapReinhardEq3", false)
		rp:SetEnabled("TonemapUncharted2", true)
		rp:SetShaderParameter("AutoExposureAdaptRate", 0.6)
		-- The floor and the ceiling are vanilla's in these units (UNITS)
		rp:SetShaderParameter("AutoExposureLumRange",
				magic.Vector2(0.015 * UNITS, 7.0 * UNITS))
		rp:SetShaderParameter("AutoExposureMiddleGrey", 0.18)
		rp:SetShaderParameter("BloomHDRThreshold", 1.2)
		rp:SetShaderParameter("BloomHDRMix", magic.Vector2(1.0, 0.03))
		rp:SetShaderParameter("TonemapExposureBias", 1.0)
		rp:SetShaderParameter("TonemapMaxWhite", 2.0)
		viewport.renderPath = rp
	end
	-- A game's set_lighting() saturation, last, in every mode; off until
	-- asked for (set_lighting()). The parity modes' path is a copy, so the
	-- pass is this viewport's alone.
	if not pbr then
		viewport.renderPath = viewport.renderPath:Clone()
	end
	self.render_path = viewport.renderPath
	self.render_path:Append(magic.cache:GetResource("XMLFile",
			"luanti_client/res/Saturation.xml"))

	-- The sounds the server asked for. A sound at a position is a node in
	-- the scene and the listener rides the camera, which is what makes it
	-- come from the right side, so this is here rather than in the
	-- extension. Keyed by the server's own id, which is what STOP_SOUND and
	-- FADE_SOUND name.
	camera_node:CreateComponent("SoundListener")
	magic.audio.listener = camera_node:GetComponent("SoundListener")

	-- How far a positioned sound carries. Luanti leaves this to OpenAL's
	-- defaults, which are in its own units; these are nodes.
	local SOUND_NEAR = 2.0
	local SOUND_FAR = 48.0

	local sounds = {}

	-- A scene node per object, kept by id. Declared here rather than with
	-- the rest of the object code below because a sound attached to an
	-- object follows it, and the sounds are above that.
	local object_nodes = {}

	world_sounds(self, magic, scene, sounds_proto, SOUND_NEAR, SOUND_FAR,
			sounds, object_nodes)

	-- Which family of connecting nodes each node id belongs to.
	--
	-- Luanti says this with node ids: a definition lists the ids it connects
	-- to, and a fence's list holds every fence and gate in the game. The
	-- mesher has voxel ids rather than node ids and one word to test, so the
	-- ids are turned into families here, once per set of definitions: two
	-- nodes are in the same family when exactly the same definitions reach
	-- out to them, which is what makes every wood's fence one family and
	-- every stone's wall another.
	--
	-- simplified: 32 families, because the mask the mesher tests is one
	-- word. A game with more gets the rest sharing the last one, which draws
	-- a connection that should not be there rather than dropping one, and
	-- says so.
	local CONNECT_GROUPS_MAX = 32
	local function connect_families(defs)
		-- Who reaches out to whom
		local referrers = {}
		for id, def in pairs(defs) do
			for _, to in ipairs(def.connects_to or {}) do
				local list = referrers[to]
				if not list then
					list = {}
					referrers[to] = list
				end
				list[#list + 1] = id
			end
		end
		local group_of = {}
		local group_of_signature = {}
		local count = 0
		local overflowed = false
		for id, list in pairs(referrers) do
			table.sort(list)
			local signature = table.concat(list, ",")
			if not group_of_signature[signature] then
				if count < CONNECT_GROUPS_MAX then
					count = count + 1
					group_of_signature[signature] = count
				else
					group_of_signature[signature] = CONNECT_GROUPS_MAX
					overflowed = true
				end
			end
			group_of[id] = group_of_signature[signature]
		end
		-- A rail is its own kind of family: Luanti has rails connect by the
		-- connect_to_raillike group rather than by connects_to, and every
		-- rail in a group connects to every other one in it.
		for id, def in pairs(defs) do
			if def.drawtype == DRAWTYPE_RAILLIKE and not group_of[id] then
				local signature = "rail:"..tostring(
						(def.groups or {}).connect_to_raillike or def.name)
				if not group_of_signature[signature] then
					if count < CONNECT_GROUPS_MAX then
						count = count + 1
						group_of_signature[signature] = count
					else
						group_of_signature[signature] = CONNECT_GROUPS_MAX
						overflowed = true
					end
				end
				group_of[id] = group_of_signature[signature]
			end
		end
		if overflowed then
			log:warning("connected nodes: more than "..CONNECT_GROUPS_MAX..
					" families of them; the rest share the last one")
		end
		return group_of
	end

	-- Which liquid family a node belongs to, as a small number, or 0 for a
	-- node that is not a liquid. Two nodes are the same liquid when they name
	-- the same source, which is how a water source and a flowing water are
	-- the same water and lava is not. The numbers are kept across registry
	-- rebuilds; there is a handful of them per game.
	local liquid_groups = {}
	local liquid_group_count = 0
	local function liquid_group(def)
		if def.liquid_type == nil or
				def.liquid_type == NODEDEF_LIQUID_NONE then
			return 0
		end
		local key = def.liquid_alternative_source
		if key == nil or key == "" then
			key = def.name
		end
		if not liquid_groups[key] then
			-- The edge material is one byte and the groups start at 11, so
			-- this cannot run away; a game with two hundred liquids gets the
			-- last of them drawn as if it were the first.
			liquid_group_count = (liquid_group_count % 200) + 1
			liquid_groups[key] = liquid_group_count
		end
		return liquid_groups[key]
	end

	-- A voxel whose six faces are the given resource names, in buildat's face
	-- order (+Y, -Y, +X, -X, +Z, -Z), which is also Luanti's tile order.
	--
	-- With shape given it is not a cube at all: the quads are the voxel's own
	-- geometry, it draws no cube faces of its own, and its neighbours draw
	-- theirs against it. shapes.lua is what builds those.
	-- turns is nil or six quarter turns, one per face: how far the texture is
	-- turned inside its own face. See VoxelDefinition.tile_turns.
	-- liquid_group is nonzero for a liquid, one number per liquid family; see
	-- liquid_group() below. connect is {group, mask, solid} for a node other
	-- nodes connect to or that connects to others; see connect_families().
	-- masked is a shape per neighbour mask instead of one shape, which is
	-- what a rail wants; see VoxelDefinition.shape_masked.
	-- blend is the node's own use_texture_alpha = "blend": see
	-- NODEDEF_ALPHAMODE_BLEND
	-- How many of the definitions built wear a texture beyond their six.
	-- Logged when a registry is done: it is the one number that says the
	-- rooted plants and the liquids' own tiles got through, and a game
	-- where it is zero is a game where they did not.
	local extras_built = 0

	-- surf is what surface.lua guessed the node is made of, or nil for the
	-- placeholder and anything else with no definition behind it
	local function add_cube(voxel_reg, name, resources, kind, shape,
			double_sided, turns, liquid_group, connect, masked, variants,
			blend, solid_base, surf)
		surf = surf or surface.for_node(nil)
		if NO_SPOTS then
			surf.spots = 0
			surf.static_spots = 0
		end
		local vdef = buildat.VoxelDefinition()
		vdef.name.block_name = name
		vdef.handler_module = ""
		local textures = {}
		for i = 1, 6 do
			local seg = buildat.AtlasSegmentDefinition()
			seg.resource_name = resources[i]
			seg.total_segments = magic.IntVector2(1, 1)
			seg.select_segment = magic.IntVector2(0, 0)
			seg.roughness = surf.roughness
			seg.spec_strength = surf.spec_strength
			seg.bumpiness = surf.bumpiness
			seg.translucency = surf.translucency
			seg.spots = surf.spots
			seg.static_spots = surf.static_spots
			textures[i] = seg
		end
		vdef.textures = textures
		-- Anything past the six is a texture a shape's quads wear of their
		-- own: the plant standing in a rooted plant's cube of ground. The
		-- list is what the quads address as tile 7 and over.
		local extras = {}
		local i = 7
		while resources[i] do
			local seg = buildat.AtlasSegmentDefinition()
			seg.resource_name = resources[i]
			seg.total_segments = magic.IntVector2(1, 1)
			seg.select_segment = magic.IntVector2(0, 0)
			seg.roughness = surf.roughness
			seg.spec_strength = surf.spec_strength
			seg.bumpiness = surf.bumpiness
			seg.translucency = surf.translucency
			seg.spots = surf.spots
			seg.static_spots = surf.static_spots
			extras[#extras + 1] = seg
			i = i + 1
		end
		if #extras > 0 then
			vdef.extra_textures = extras
			extras_built = extras_built + 1
		end
		if turns then
			vdef.tile_turns = turns
		end
		if liquid_group and liquid_group ~= 0 then
			-- One edge material per liquid family, so water culls against
			-- water and lava against lava while the face between them is
			-- drawn -- and so is the terrain under either, because ground is
			-- neither.
			vdef.edge_material_id = EDGEMATERIAL_LIQUID + liquid_group - 1
			vdef.shape_group = liquid_group
		elseif kind == "glass" then
			vdef.edge_material_id = EDGEMATERIAL_GLASS
		elseif kind == "allfaces" then
			vdef.face_draw_type =
					buildat.VoxelDefinition.FACEDRAWTYPE_ALWAYS
			vdef.edge_material_id =
					buildat.VoxelDefinition.EDGEMATERIALID_GROUND
		else
			vdef.edge_material_id =
					buildat.VoxelDefinition.EDGEMATERIALID_GROUND
		end
		vdef.physically_solid = true
		if connect then
			vdef.connect_group = connect.group or 0
			vdef.connect_mask = connect.mask or 0
			vdef.connect_to_solid = connect.solid and true or false
		end
		-- Which pass the faces go in. The mesher puts a translucent voxel's
		-- faces on a child node of the chunk and world.lua gives that one the
		-- blended technique.
		--
		-- A liquid always, and anything the game asked to be blended rather
		-- than alpha masked: that is what use_texture_alpha = "blend" means,
		-- and without reading it framed glass and panes are drawn with every
		-- texel either solid or gone where the game meant them to be seen
		-- through.
		vdef.translucent = (liquid_group ~= nil and liquid_group ~= 0) or
				blend == true
		if liquid_group ~= nil and liquid_group ~= 0 then
			-- Where the surface stands, which is what the mesher averages
			-- across the voxels around each corner: the top of the shape for
			-- a flowing liquid, and the top of the voxel for a source, which
			-- is what a neighbour's corner rises to.
			vdef.is_liquid = true
			local top = 0.5
			if shape then
				top = -0.5
				for _, quad in ipairs(shape) do
					for i = 2, 11, 3 do
						if quad.p[i] > top then
							top = quad.p[i]
						end
					end
				end
			end
			vdef.liquid_top = top
		end
		if shape then
			vdef.shape = shape
			if masked then
				vdef.shape_masked = masked
			end
			vdef.shape_double_sided = double_sided and true or false
			-- A shape whose voxel is solid ground keeps its six faces: they
			-- are the ground, and the shape standing on them is only what
			-- grows out of it
			if not solid_base then
				vdef.face_draw_type =
						buildat.VoxelDefinition.FACEDRAWTYPE_NEVER
			end
			-- A shaped voxel's neighbours draw their faces against it, which
			-- is what EMPTY says. A liquid keeps its own edge material
			-- instead: a lake's cubes must not draw their faces against the
			-- shaped surface on top of them. So does a shape that fills the
			-- voxel anyway; see rooted_quads().
			if not (liquid_group and liquid_group ~= 0) and
					not solid_base then
				vdef.edge_material_id =
						buildat.VoxelDefinition.EDGEMATERIALID_EMPTY
			end
			-- And such a shape is lit by the voxel it stands in rather than
			-- by its own, which is solid ground: a plant on the sea bed is
			-- under the water above it, not in the open.
			vdef.shape_lit_from_above = solid_base and true or false
		end
		if variants then
			vdef.variants = variants
		end
		return voxel_reg:add_voxel(vdef)
	end

	-- The registry as it is until the node definitions arrive: air, and one
	-- placeholder cube for everything else. begin_node_definitions() replaces
	-- it with one built from what the server says the nodes are.
	local function base_registry()
		local voxel_reg = buildat.createVoxelRegistry()
		-- Luanti's own cut of a 32-bit node, which fits buildat's voxel
		-- word exactly: a 16-bit node id, param1 as two light nibbles, and
		-- param2. What the param buys is that a node's facing and a flowing
		-- liquid's level reach the mesher as data instead of as a voxel type
		-- per (definition, param2) pair; see build_variants().
		voxel_reg:set_format{
			plane_bits = 32,
			id = {shift = 0, width = 16},
			light_sky = {shift = 16, width = 4},
			light_lamp = {shift = 20, width = 4},
			param = {shift = 24, width = 8},
		}
		local vdef = buildat.VoxelDefinition()
		vdef.name.block_name = "air"
		vdef.handler_module = ""
		-- Air draws no faces of its own; the solid voxel next to it draws the
		-- face between them
		vdef.face_draw_type = buildat.VoxelDefinition.FACEDRAWTYPE_NEVER
		vdef.edge_material_id = buildat.VoxelDefinition.EDGEMATERIALID_EMPTY
		vdef.physically_solid = false
		vdef.fully_empty = true
		voxel_reg:add_voxel(vdef) -- VOXEL_AIR
		add_cube(voxel_reg, "placeholder",
				{texture, texture, texture, texture, texture, texture},
				"ground") -- VOXEL_PLACEHOLDER
		return voxel_reg
	end

	-- On self rather than in a local: begin_node_definitions() replaces both,
	-- and mesh_block() has to use whichever is current
	self.voxel_reg = base_registry()
	local function new_atlas_registry()
		local reg = buildat.createAtlasRegistry()
		-- The PBR shader samples the normal and surface maps the registry
		-- derives from each texture; the unlit one samples the diffuse atlas
		-- and nothing else, and deriving the other two is two thirds of what
		-- adding a texture to an atlas costs. That loading time is what the
		-- connect dialog's checkbox spends.
		reg:set_surface_maps(pbr)
		return reg
	end

	self.atlas_reg = new_atlas_registry()

	-- key -> {x=, y=, z=, param0=, param1=, node=}
	local blocks = {}
	-- key -> true for blocks whose mesh is out of date
	local dirty = {}
	local dirty_count = 0

	self.node_map = PLACEHOLDER_MAP
	self.node_map_default = VOXEL_PLACEHOLDER
	-- pack_voxel_volume() compiles a map once per (id, version) rather than
	-- once per source: a map of a few thousand node ids costs more to compile
	-- than the whole block copy does, and every source of every block hands
	-- in the same two maps. The ids are ours to pick; the versions say when a
	-- map has changed. See doc/client_api.txt.
	local MAP_ID_NODE, MAP_ID_PAIR, MAP_ID_LIGHT = 1, 2, 3
	-- The PBR path's curve is a different table and so needs an id of its own;
	-- the compiled maps are cached by id
	local MAP_ID_LIGHT_PBR = 4
	local light_map = pbr and PBR_LIGHT_MAP or LIGHT_MAP
	local light_map_id = pbr and MAP_ID_LIGHT_PBR or MAP_ID_LIGHT
	self.node_map_version = 1
	self.pair_map_version = 1
	self.use_skylight = true
	-- id -> true for the nodes the player collides with, and for the ones it
	-- swims in. nil rather than a table means the definitions have not
	-- arrived and everything but air is solid; see is_solid().
	self.node_solid = nil
	self.node_liquid = {}
	self.node_resistance = {}
	self.node_groups = {}
	-- The screen tint of the node the camera is in, per node id; see
	-- post_effect_at(). Only the nodes that have one are in here.
	self.node_post_effect = {}
	-- What the pointed-node outline goes around, per node id; see
	-- selection_at(). A node that is not in here is outlined as a whole
	-- voxel.
	self.node_selection = {}
	-- id -> false for the nodes a pointing ray goes through; nil means the
	-- definitions have not arrived and everything but air stops one
	self.node_pointable = nil

	-- One voxel id per (definition, palette colour), for the pairs that turn
	-- up in a block that arrives. The map is keyed the way the paired lookup
	-- wants; pair_voxel is keyed by what actually decides the look, so two
	-- param2 values that pick the same palette colour share a voxel id.
	--
	-- A colour is the only thing param2 says that still costs a voxel type:
	-- it tints the texture, and the tint has to be composed into one. The
	-- rest -- which way a voxel faces, how high its liquid stands -- reaches
	-- the mesher as the param itself; see build_variants().
	self.pair_map = {}
	self.pair_count = 0
	local pair_voxel = {}
	-- Bumped when the definitions change: every block has to be looked at
	-- again, because what its param2 means has changed
	local pair_epoch = 0
	-- id -> {def =, step =, colors =, variants =} for the definitions whose
	-- param2 is a palette index; nil for everything else. What param2 says
	-- about a voxel's shape does not come through here any more -- that is
	-- what the definitions' variants carry -- so this is only about colour.
	local param2_look = {}
	-- Set by begin_node_definitions(), which is what knows how to build one
	local build_pair = nil

	-- The pairs in one block that have no voxel id yet. Scanning 4096 voxels
	-- in Lua is not free, so it happens once per block rather than once per
	-- mesh, and only while some definition cares about param2 at all.
	local function register_pairs(block)
		if not build_pair or not block.param2 or not next(param2_look) then
			return
		end
		if block.pair_epoch == pair_epoch then
			return
		end
		block.pair_epoch = pair_epoch
		local param0, param2 = block.param0, block.param2
		local n = BLOCKSIZE * BLOCKSIZE * BLOCKSIZE
		for i = 0, n - 1 do
			local hi, lo = param0:byte(i * 2 + 1, i * 2 + 2)
			local entry = param2_look[hi * 256 + lo]
			if entry then
				local p2 = param2:byte(i + 1)
				local key = hi * 256 + lo + p2 * PAIR_SCALE
				if self.pair_map[key] == nil then
					build_pair(entry, hi * 256 + lo, p2, key)
				end
			end
		end
	end

	local function mark_dirty(key)
		if blocks[key] and not dirty[key] then
			dirty[key] = true
			dirty_count = dirty_count + 1
		end
	end

	-- Where the block's scene node goes. A voxel v of the block ends up at
	-- world blockpos * 16 + v, which is the Luanti node coordinate.
	local function block_node_position(x, y, z)
		local half = BLOCKSIZE / 2 - 0.5
		return magic.Vector3(x * BLOCKSIZE + half, y * BLOCKSIZE + half,
				z * BLOCKSIZE + half)
	end

	-- The seven box copies that make one block's volume: the block itself, and
	-- the one-node slice of each neighbour that has arrived.
	local function volume_sources(block)
		local sources = {
			{
				data = block.param0, format = "u16be",
				source_size = {BLOCKSIZE, BLOCKSIZE, BLOCKSIZE},
				at = {0, 0, 0},
				map = self.node_map, map_default = self.node_map_default,
				map_id = MAP_ID_NODE, map_version = self.node_map_version,
			},
		}
		-- A second pass over the same box for the voxels whose param2 says
		-- what they look like: no map_default, so a pair that has no voxel id
		-- of its own leaves what the pass above wrote alone. That is what
		-- keeps this from having to hold an entry for every (id, param2)
		-- pair in the game.
		if self.pair_count > 0 and block.param2 then
			sources[#sources + 1] = {
				data = block.param0, format = "u16be",
				source_size = {BLOCKSIZE, BLOCKSIZE, BLOCKSIZE},
				at = {0, 0, 0},
				second = {data = block.param2, format = "u8",
						scale = PAIR_SCALE},
				map = self.pair_map,
				map_id = MAP_ID_PAIR, map_version = self.pair_map_version,
			}
		end
		-- param2 itself, which the definitions interpret: which way a voxel
		-- faces, how high its liquid stands. No map -- it goes in as it is.
		if block.param2 then
			sources[#sources + 1] = {
				data = block.param2, format = "u8",
				source_size = {BLOCKSIZE, BLOCKSIZE, BLOCKSIZE},
				at = {0, 0, 0}, field = "param",
			}
		end
		if self.use_skylight then
			sources[#sources + 1] = {
				data = block.param1, format = "u8",
				source_size = {BLOCKSIZE, BLOCKSIZE, BLOCKSIZE},
				at = {0, 0, 0}, map = light_map, field = "light",
				map_id = light_map_id, map_version = 1,
			}
		end
		for _, d in ipairs(NEIGHBOURS) do
			local n = blocks[block_key(block.x + d[1], block.y + d[2],
					block.z + d[3])]
			if n then
				-- The slice facing us: the neighbour's last plane on a
				-- negative side, its first on a positive one
				local from, size, at = {0, 0, 0}, {BLOCKSIZE, BLOCKSIZE,
						BLOCKSIZE}, {0, 0, 0}
				for i = 1, 3 do
					if d[i] < 0 then
						from[i] = BLOCKSIZE - 1
						size[i] = 1
						at[i] = -1
					elseif d[i] > 0 then
						from[i] = 0
						size[i] = 1
						at[i] = BLOCKSIZE
					end
				end
				sources[#sources + 1] = {
					data = n.param0, format = "u16be",
					source_size = {BLOCKSIZE, BLOCKSIZE, BLOCKSIZE},
					from = from, size = size, at = at,
					map = self.node_map, map_default = self.node_map_default,
					map_id = MAP_ID_NODE, map_version = self.node_map_version,
				}
				if self.pair_count > 0 and n.param2 then
					sources[#sources + 1] = {
						data = n.param0, format = "u16be",
						source_size = {BLOCKSIZE, BLOCKSIZE, BLOCKSIZE},
						from = from, size = size, at = at,
						second = {data = n.param2, format = "u8",
								scale = PAIR_SCALE},
						map = self.pair_map,
						map_id = MAP_ID_PAIR,
						map_version = self.pair_map_version,
					}
				end
				if n.param2 then
					sources[#sources + 1] = {
						data = n.param2, format = "u8",
						source_size = {BLOCKSIZE, BLOCKSIZE, BLOCKSIZE},
						from = from, size = size, at = at,
						field = "param",
					}
				end
				if self.use_skylight then
					sources[#sources + 1] = {
						data = n.param1, format = "u8",
						source_size = {BLOCKSIZE, BLOCKSIZE, BLOCKSIZE},
						from = from, size = size, at = at,
						map = light_map, field = "light",
						map_id = light_map_id, map_version = 1,
					}
				end
			end
		end
		return sources
	end

	-- Microseconds the last block spent being packed and handed to the
	-- mesher. The meshing itself is on a worker thread; this is what it costs
	-- the frame.
	self.last_mesh_us = 0

	-- What colour a light source shines in: the average of its own first
	-- tile, brightest channel brought up to one so that how bright it is
	-- stays the light level's business. A torch is then warm and a soul
	-- torch is blue without anything having to know what either is.
	--
	-- Luanti has one number for this -- light_source -- and paints every
	-- source the same; the plan's "rendering does not have to match" is what
	-- this leans on.
	local light_color_cache = {}

	local function light_color(resource)
		if not resource or not read_image then
			return LIGHT_COLOR
		end
		local held = light_color_cache[resource]
		if held then
			return held
		end
		local color = LIGHT_COLOR
		local ok, w, h, rgba = pcall(read_image, resource)
		if ok and rgba and w and h and w > 0 and h > 0 then
			local r, g, b, weight = 0, 0, 0, 0
			-- Every fourth pixel is enough of an average and a 64x64 tile is
			-- four thousand of them
			for i = 0, w * h - 1, 4 do
				local pr, pg, pb, pa = rgba:byte(i * 4 + 1, i * 4 + 4)
				if pa and pa > 128 then
					r = r + pr
					g = g + pg
					b = b + pb
					weight = weight + 1
				end
			end
			if weight > 0 then
				local top = math.max(r, g, b)
				if top > 0 then
					color = {r = r / top, g = g / top, b = b / top}
				end
			end
		end
		light_color_cache[resource] = color
		return color
	end

	-- Where the voxels that give light are in a block, in world
	-- coordinates, and how bright: what a scene light is put at.
	--
	-- simplified: only the first MAX_LIGHTS_PER_BLOCK of a block are kept,
	-- and which those are is whichever the scan meets first rather than the
	-- brightest.
	local function find_lights(block)
		local levels = self.node_light
		if not levels or not next(levels) then
			return nil
		end
		local out = nil
		local param0 = block.param0
		local n = BLOCKSIZE * BLOCKSIZE * BLOCKSIZE
		for i = 0, n - 1 do
			local hi, lo = param0:byte(i * 2 + 1, i * 2 + 2)
			local light = levels[hi * 256 + lo]
			if light then
				out = out or {}
				-- The index order is x fastest, then y, then z
				local x = i % BLOCKSIZE
				local y = math.floor(i / BLOCKSIZE) % BLOCKSIZE
				local z = math.floor(i / (BLOCKSIZE * BLOCKSIZE))
				out[#out + 1] = {
					block.x * BLOCKSIZE + x,
					block.y * BLOCKSIZE + y,
					block.z * BLOCKSIZE + z,
					light.level,
					light.color,
				}
				if #out >= MAX_LIGHTS_PER_BLOCK then
					break
				end
			end
		end
		return out
	end

	-- The lights that are in the scene now, as scene nodes kept and reused:
	-- creating and destroying a light every time the player moves would cost
	-- more than the lighting does.
	local light_pool = {}
	local lights_stale = true
	local lights_at = nil

	-- Puts the scene's lights on the light-giving voxels nearest the camera.
	local function place_lights()
		-- None on the pbr path: its baked lamp term is the torch's light
		-- there, in the sky's units, where these at 0.1 to 0.4 in the
		-- display's were nothing but a redraw each ([TORCH_LIGHT])
		if pbr then
			return
		end
		local p = camera_node.position
		local reach = 60
		local best = {}
		for _, block in pairs(blocks) do
			if block.lights then
				for _, l in ipairs(block.lights) do
					local dx, dy, dz = l[1] - p.x, l[2] - p.y, l[3] - p.z
					local d = dx * dx + dy * dy + dz * dz
					if d < reach * reach then
						best[#best + 1] = {d = d, l = l}
					end
				end
			end
		end
		table.sort(best, function(a, b) return a.d < b.d end)
		for i = 1, MAX_SCENE_LIGHTS do
			local entry = best[i]
			local held = light_pool[i]
			if entry and not held then
				local node = scene:CreateChild("light_"..i)
				held = {node = node, light = node:CreateComponent("Light")}
				held.light.lightType = magic.LIGHT_POINT
				held.light.castShadows = false
				-- The world's own light is diffuse; a highlight moving
				-- about on a painted texture only looks wrong
				held.light.specularIntensity = 0
				light_pool[i] = held
			end
			if held then
				if entry then
					local l = entry.l
					held.node.position = magic.Vector3(l[1], l[2], l[3])
					held.light.range = l[4] * LIGHT_RANGE_PER_LEVEL
					-- Luanti's light levels run to 14, and a torch is 12.
					-- Kept low: this is added on top of the light the
					-- mesher already baked in, and a cave with a few
					-- torches in it washes out otherwise.
					held.light.brightness = 0.1 + l[4] / 14 * 0.3
					-- Setting a colour is a sandbox call; most of these
					-- keep the one they have from one frame to the next
					local color = l[5] or LIGHT_COLOR
					if color ~= held.color then
						held.color = color
						held.light.color = magic.Color(color.r, color.g,
								color.b)
					end
					held.node.enabled = true
				else
					held.node.enabled = false
				end
			end
		end
	end

	-- Defined with the rest of the sky-visibility cache below, which is after
	-- this because it packs a block the same way this does
	local vis_volumes_drop
	local function mesh_block(key)
		local block = blocks[key]
		if not block then
			return
		end
		local t0 = buildat.get_time_us()
		-- What the voxels in it look like may depend on their param2, and a
		-- pair that has no voxel id of its own draws as if its param2 were
		-- zero. Here rather than when the block arrives, because the blocks
		-- that were already there when the definitions came have to be
		-- looked at too, and meshing is already spread over frames.
		register_pairs(block)
		if not block.node then
			block.node = scene:CreateChild("block_"..key)
			block.node.position = block_node_position(block.x, block.y, block.z)
		end
		local data = buildat.pack_voxel_volume{
			region = {VOLUME_MIN, VOLUME_MIN, VOLUME_MIN,
					VOLUME_MAX, VOLUME_MAX, VOLUME_MAX},
			-- Whose format the field names mean; see base_registry()
			registry = self.voxel_reg,
			fill = VOXEL_AIR_LIT,
			sources = volume_sources(block),
		}
		-- Only when this block's own voxels have changed: scanning 4096 of
		-- them in Lua is not free, and a block is meshed again every time a
		-- neighbour arrives
		if block.lights == nil then
			block.lights = find_lights(block) or false
			if block.lights or block.had_lights then
				block.had_lights = block.lights and true or nil
				lights_stale = true
			end
		end
		-- The sky-visibility cache holds a copy of this block's voxels; it
		-- is rebuilt from the block the next time it is wanted
		vis_volumes_drop(key)
		local node = block.node
		-- The seventh is the horizon the vanilla client packs into its
		-- meshes ([PBR_FIT] 2c); none here, and luabind wants every argument
		buildat.set_voxel_geometry(node, data, self.voxel_reg,
				self.atlas_reg, self.use_skylight,
				function() apply_technique(node) end, "")
		self.last_mesh_us = buildat.get_time_us() - t0
		-- The worst single block of the frame, for the slow-frame line: one
		-- block that costs ten times what the others do is a different
		-- problem from eight that each cost their share
		if self.last_mesh_us > (self.worst_mesh_us or 0) then
			self.worst_mesh_us = self.last_mesh_us
		end
	end

	-- The voxel data the sky-visibility marching walks through, when the PBR
	-- path is on: a Volume per block near the camera, which is data this
	-- client does not otherwise keep -- it packs a block, hands it to the
	-- mesher and forgets it. Packing it again and deserializing is the way in.
	--
	-- Built a few blocks a frame rather than a set at a time. A ray that
	-- leaves the volumes it was given keeps the skylight of the last air it
	-- was in, so a block that is not built yet reads as whatever is around it
	-- rather than as a wall: the answers start open and tighten as the cache
	-- fills, which is the right way round for a player walking into a cave.
	local VIS_MARGIN = 32              -- Voxels around the camera
	local VIS_BUILD_PER_CALL = 8
	local vis_volumes = {}             -- key -> {x=, y=, z=, volume=}
	local vis_list = {}                -- The same entries, as collect wants
	local vis_chunk_size = {x = BLOCKSIZE, y = BLOCKSIZE, z = BLOCKSIZE}

	-- No border: the marching steps from block to block through the list, so
	-- the slice of a neighbour the mesher needs is somebody else's copy here
	local function vis_volume_of(block)
		return buildat.deserialize_volume(buildat.pack_voxel_volume{
			region = {0, 0, 0, BLOCKSIZE - 1, BLOCKSIZE - 1, BLOCKSIZE - 1},
			registry = self.voxel_reg,
			fill = VOXEL_AIR_LIT,
			sources = volume_sources(block),
		})
	end

	-- A block whose voxels have changed: the copy here is stale
	vis_volumes_drop = function(key)
		vis_volumes[key] = nil
	end

	local function collect_vis_volumes(origin)
		local r = math.ceil(VIS_MARGIN / BLOCKSIZE)
		local cx = math.floor(origin.x / BLOCKSIZE)
		local cy = math.floor(origin.y / BLOCKSIZE)
		local cz = math.floor(origin.z / BLOCKSIZE)
		local wanted = {}
		local n = 0
		local built = 0
		for z = cz - r, cz + r do
			for y = cy - r, cy + r do
				for x = cx - r, cx + r do
					local key = block_key(x, y, z)
					local block = blocks[key]
					if block then
						wanted[key] = true
						local entry = vis_volumes[key]
						if entry == nil and built < VIS_BUILD_PER_CALL then
							entry = {x = x, y = y, z = z,
									volume = vis_volume_of(block)}
							vis_volumes[key] = entry
							built = built + 1
						end
						if entry then
							n = n + 1
							vis_list[n] = entry
						end
					end
				end
			end
		end
		for i = #vis_list, n + 1, -1 do
			vis_list[i] = nil
		end
		-- What has gone out of range, or been dropped, or been replaced
		for key, _ in pairs(vis_volumes) do
			if not wanted[key] then
				vis_volumes[key] = nil
			end
		end
		if n == 0 then
			return nil
		end
		return {chunk_size = vis_chunk_size, registry = self.voxel_reg,
				volumes = vis_list}
	end

	-- Only with the PBR path: nothing else reads it, and it is a worker
	-- thread's worth of ray marching a frame
	local vis = pbr and skyvis.new(magic, buildat, collect_vis_volumes) or nil
	-- Where the camera was last frame, to tell a step from a teleport
	local vis_at = nil
	local cave_floor_now = nil
	local CAVE_FLOOR_GAIN = 0.48

	local function update_sky_visibility()
		if not vis then return end
		local p = camera_node.position
		-- A teleport, or the first frame: march the whole cube at once rather
		-- than easing towards it over the next second, so that what is on
		-- screen straight after is settled
		local moved = vis_at and math.max(math.abs(p.x - vis_at[1]),
				math.abs(p.y - vis_at[2]), math.abs(p.z - vis_at[3])) or nil
		vis_at = {p.x, p.y, p.z}
		vis:update(p, (moved ~= nil and moved < 8) and 1 or nil)
		-- Vanilla's cave floor in these units, only where the camera sees
		-- no sky, as vanilla scales its own by how dark the chamber is
		-- ([CAVE_EXPOSURE_FLOOR]): everywhere it lifted the moonlit snow
		-- a third. simplified: the most sky any direction sees stands in
		-- for vanilla's chamber reading, which also counts daylit faces
		-- in sight; a cave lit round a corner reads darker here.
		-- CAVE_FLOOR_GAIN is measured, not derived: at vanilla's value the
		-- closed cave read 43/255 to vanilla's 27.7; with the shade on it
		-- (the alpha's low nibble), at 0.48 of it pbr_pair reads 20.2 to
		-- 21.3, the corners seen.
		-- Set only on a change: set_param walks the render path.
		local cf = PHYS.cave_floor * UNITS * CAVE_FLOOR_GAIN *
				(1 - math.min(1, vis:most()))
		if not cave_floor_now or math.abs(cf - cave_floor_now) > cf * 0.02 + 1e-6 then
			cave_floor_now = cf
			vis:set_param("CaveAmbient", magic.Vector3(cf, cf, cf))
		end
	end

	-- For the counters: how much sky the shader is being told there is
	-- straight up, and how many blocks' voxels that answer was marched
	-- through. nil when the PBR path is off, which is what says not to show
	-- the counter at all.
	function self:sky_visibility()
		if not vis then return nil end
		return vis:value_of(skyvis.cell_of(0, 1, 0)), #vis_list
	end

	-- A block that arrived from the server. Its own mesh and its neighbours'
	-- are then out of date, because their borders come from each other.
	function self:set_block(block)
		local key = block_key(block.x, block.y, block.z)
		local existing = blocks[key]
		if existing then
			existing.param0 = block.param0
			existing.param1 = block.param1
			existing.param2 = block.param2
			existing.meta = block.meta
			existing.lights = nil -- Its voxels have changed
			existing.pair_epoch = nil
		else
			blocks[key] = {
				x = block.x, y = block.y, z = block.z,
				param0 = block.param0, param1 = block.param1,
				param2 = block.param2, meta = block.meta,
			}
		end
		mark_dirty(key)
		for _, d in ipairs(NEIGHBOURS) do
			mark_dirty(block_key(block.x + d[1], block.y + d[2],
					block.z + d[3]))
		end
	end

	-- How many (definition, param2) pairs have a voxel id of their own, for
	-- the counters: this is what says whether the palettes are being used
	function self:pair_voxel_count()
		return self.pair_count
	end

	-- What hangs off the voxel at a node position: {fields =, lists =}, or
	-- nil. The metadata came with the block the voxel is in, keyed by the
	-- index into it.
	function self:node_meta(x, y, z)
		local bx = math.floor(x / BLOCKSIZE)
		local by = math.floor(y / BLOCKSIZE)
		local bz = math.floor(z / BLOCKSIZE)
		local block = blocks[block_key(bx, by, bz)]
		if not block or not block.meta then
			return nil
		end
		local ix = x - bx * BLOCKSIZE
		local iy = y - by * BLOCKSIZE
		local iz = z - bz * BLOCKSIZE
		return block.meta[(iz * BLOCKSIZE + iy) * BLOCKSIZE + ix]
	end

	-- The metadata a server changed, keyed by "x,y,z": it goes into the block
	-- that holds each position, so that dropping the block drops it too.
	function self:set_node_meta(entries)
		for at, entry in pairs(entries) do
			local x, y, z = at:match("^(-?%d+),(-?%d+),(-?%d+)$")
			if x then
				x, y, z = tonumber(x), tonumber(y), tonumber(z)
				local bx = math.floor(x / BLOCKSIZE)
				local by = math.floor(y / BLOCKSIZE)
				local bz = math.floor(z / BLOCKSIZE)
				local block = blocks[block_key(bx, by, bz)]
				if block then
					block.meta = block.meta or {}
					local i = ((z - bz * BLOCKSIZE) * BLOCKSIZE +
							(y - by * BLOCKSIZE)) * BLOCKSIZE +
							(x - bx * BLOCKSIZE)
					block.meta[i] = entry
				end
			end
		end
	end

	-- The Luanti content id at a node position, or nil if the block holding
	-- it has not arrived. param0 is two big-endian bytes per node, x fastest.
	function self:node_at(x, y, z)
		local bx = math.floor(x / BLOCKSIZE)
		local by = math.floor(y / BLOCKSIZE)
		local bz = math.floor(z / BLOCKSIZE)
		local block = blocks[block_key(bx, by, bz)]
		if not block then
			return nil
		end
		local i = (x - bx * BLOCKSIZE) +
				(y - by * BLOCKSIZE) * BLOCKSIZE +
				(z - bz * BLOCKSIZE) * BLOCKSIZE * BLOCKSIZE
		local hi, lo = block.param0:byte(i * 2 + 1, i * 2 + 2)
		return hi * 256 + lo
	end

	-- param1 (the two light nibbles) at a node position, or nil if the block
	-- holding it has not arrived.
	local function param1_at(x, y, z)
		local bx = math.floor(x / BLOCKSIZE)
		local by = math.floor(y / BLOCKSIZE)
		local bz = math.floor(z / BLOCKSIZE)
		local block = blocks[block_key(bx, by, bz)]
		if not block then
			return nil
		end
		local i = (x - bx * BLOCKSIZE) +
				(y - by * BLOCKSIZE) * BLOCKSIZE +
				(z - bz * BLOCKSIZE) * BLOCKSIZE * BLOCKSIZE
		return block.param1:byte(i + 1)
	end

	-- What light a node that just became air has. The server does not send
	-- light for a removal and Luanti's own client runs a light flood there;
	-- this takes the brightest neighbour and dims it by one step instead,
	-- separately for sunlight and for lamplight, and keeps full sunlight
	-- undimmed so that a column dug down from the open sky stays lit.
	--
	-- simplified: one node deep. Digging a tunnel is right anyway, because
	-- each node in turn sees the one behind it, but a node that should have
	-- gone *darker* (or brighter through a corner) only catches up when the
	-- server resends the block. A real flood fill is the upgrade.
	-- The param2 of the voxel at a node position, or 0 when the block is not
	-- here: which way it faces, or what colour it is
	local function param2_at(x, y, z)
		local bx = math.floor(x / BLOCKSIZE)
		local by = math.floor(y / BLOCKSIZE)
		local bz = math.floor(z / BLOCKSIZE)
		local block = blocks[block_key(bx, by, bz)]
		if not block or not block.param2 then
			return 0
		end
		local i = ((z - bz * BLOCKSIZE) * BLOCKSIZE +
				(y - by * BLOCKSIZE)) * BLOCKSIZE + (x - bx * BLOCKSIZE)
		return block.param2:byte(i + 1) or 0
	end

	local function removal_light(x, y, z)
		local day, night = 0, 0
		for _, d in ipairs(NEIGHBOURS) do
			local p = param1_at(x + d[1], y + d[2], z + d[3])
			if p then
				local nd, nn = p % 16, math.floor(p / 16)
				-- Straight down from the open sky does not dim
				if nd > 0 and not (nd == 15 and d[2] > 0) then
					nd = nd - 1
				end
				if nn > 0 then
					nn = nn - 1
				end
				if nd > day then day = nd end
				if nn > night then night = nn end
			end
		end
		return night * 16 + day
	end

	-- Whether a node stops the player. A node whose block has not arrived,
	-- and one the server says is not generated, both count as solid, which is
	-- what Luanti's own collision does with them: standing still in a world
	-- that has not loaded is better than falling through it.
	--
	-- Until the node definitions arrive nothing is known but air, and
	-- everything else is drawn as a placeholder cube, so that is what it
	-- collides as.
	-- What the player runs into at a node position: false for nothing, true
	-- for the whole voxel, or the boxes it is made of -- a slab, a stair, a
	-- fence post -- in the voxel's own -0.5...0.5 coordinates.
	function self:is_solid(x, y, z)
		local id = self:node_at(x, y, z)
		if id == nil or id == CONTENT_IGNORE then
			return true
		end
		if id == CONTENT_AIR then
			return false
		end
		if self.node_solid then
			-- A node the definitions did not cover is drawn as a placeholder
			-- cube, so it collides as one; only what the server says is not
			-- walkable is walked through
			if self.node_solid[id] == false then
				return false
			end
			local entry = self.node_collision and self.node_collision[id]
			if entry then
				-- The boxes turn with the voxel, the same way its shape does
				local facedir = entry.facing and shapes.facedir_of(
						entry.facing, param2_at(x, y, z)) or nil
				if not facedir or facedir == 0 then
					return entry.boxes
				end
				local key = facedir
				entry.turned = entry.turned or {}
				if not entry.turned[key] then
					entry.turned[key] = turn_boxes(entry.boxes, facedir)
				end
				return entry.turned[key]
			end
			return true
		end
		return true
	end

	-- The colour to paint over the whole screen because the camera is in this
	-- node, as Luanti's post_effect_color {a, r, g, b} in 0...255, or nil for
	-- a node that has none. What this is for is being under water.
	function self:post_effect_at(x, y, z)
		local id = self:node_at(x, y, z)
		if id == nil then
			return nil
		end
		return self.node_post_effect[id]
	end

	-- Whether a node is something to swim in
	function self:is_liquid(x, y, z)
		local id = self:node_at(x, y, z)
		return id ~= nil and self.node_liquid[id] == true
	end

	-- The node's move_resistance, 0 where there is no node yet
	function self:resistance_at(x, y, z)
		local id = self:node_at(x, y, z)
		return (id ~= nil and self.node_resistance[id]) or 0
	end

	-- The node's groups, nil where there is no node yet: what standing on it
	-- does (bouncy, slippery, ...) and what landing on it costs
	function self:groups_at(x, y, z)
		local id = self:node_at(x, y, z)
		return id ~= nil and self.node_groups[id] or nil
	end

	-- Whether a ray stops at a node. Air does not stop one and neither does
	-- a node the game says is not pointable; a node whose block has not
	-- arrived does not either, because pointing at nothing is better than
	-- digging at a guess.
	function self:is_pointable(x, y, z)
		local id = self:node_at(x, y, z)
		if id == nil or id == CONTENT_AIR or id == CONTENT_IGNORE then
			return false
		end
		if self.node_pointable then
			return self.node_pointable[id] ~= false
		end
		return true
	end

	local pointed_node = world_pointing(self, magic, scene, camera_node,
			game_texture)

	--
	-- The things in the world that are not nodes
	--

	local object_technique = magic.cache:GetResource("Technique",
			"luanti_client/res/UnlitAlphaMask.xml")
	local box_model = magic.cache:GetResource("Model", "Models/Box.mdl")
	-- Particles are blended rather than cut out -- smoke and a spark are
	-- soft-edged -- and unlit, like the objects. Urho3D ships the technique.
	local particle_technique = magic.cache:GetResource("Technique",
			"Techniques/DiffUnlitParticleAlpha.xml")

	-- The light an object is drawn in. Its texture goes on unlit -- the
	-- entities of this game are drawn unlit in Luanti's own client too, and
	-- their textures are full of holes -- so what stands in for the light is
	-- a colour the shader multiplies the texture by, worked out the same way
	-- the voxel around it is lit. Without this a mob is as bright at midnight
	-- as at noon.
	--
	-- Which way that is worked out depends on the path, because the two light
	-- a voxel differently and an object beside one has to agree with it. The
	-- vanilla path bakes the sunlight colour into the vertices and that is
	-- all there is; the PBR path has a sky for an ambient and a sun of its
	-- own on top, so an object gets both. There is no normal to take a real
	-- share of the sun by -- that is what unlit means -- so it gets a fixed
	-- one, which is what a thing standing in the sun shows on average.
	-- How much of the sun an object shows. One number has to serve for both
	-- a mob in the open and one under a tree, because an unlit thing has no
	-- normal to shadow: measured on the ground it stands on, sunlit grass
	-- renders at about twelve times the same grass in a shadow, and what is
	-- picked here lands an object between the two. It is the number to move
	-- if mobs read as glowing in a wood or as cut out in a field.
	local OBJECT_SUN = 1.0
	-- What something in the pitch dark is worth, so that it is a silhouette
	-- rather than nothing. Small, because the ambient it is added to is small
	-- at night and a mob that glows is worse than one that is hard to see.
	local OBJECT_DARK_FLOOR = 0.01
	-- What the sun is worth to an object now: its colour and how much of it
	-- there is, kept by apply_daylight() because that is where it is known
	local object_sun = nil

	-- lit: for a mesh under pbr ([OBJECT_SUN]), drawn through the lit
	-- passes, which add the zone's ambient times this colour and the sun
	-- with its direction and shadow: so no sun share here, and the light
	-- over the ambient the shader multiplies it by.
	-- simplified: the ambient is the zone's, not the sky a face sees, so a
	-- model's shaded side reads lighter than a shaded voxel side does.
	-- glow: a particle's, which raises its light to that level, Luanti's rule.
	local function object_color(x, y, z, lit, glow)
		local p1 = param1_at(math.floor(x + 0.5), math.floor(y + 0.5),
				math.floor(z + 0.5))
		if not p1 then
			return nil
		end
		local day = p1 % 16
		local night = math.floor(p1 / 16)
		local sky = (day > night and day - night or 0) / 15
		local lamp = math.max(night, glow or 0) / 15
		-- A floor of a few percent, so that something in the pitch dark is a
		-- silhouette rather than nothing at all
		if pbr and lit then
			local amb = zone.ambientColor
			local function over(a)
				return a > 1e-6 and (a * sky + lamp + OBJECT_DARK_FLOOR) / a or 0
			end
			return magic.Color(over(amb.r), over(amb.g), over(amb.b))
		end
		if pbr then
			local amb = zone.ambientColor
			local sun = object_sun
			local sr, sg, sb = 0, 0, 0
			if sun then
				sr = sun.r * sun.a * OBJECT_SUN
				sg = sun.g * sun.a * OBJECT_SUN
				sb = sun.b * sun.a * OBJECT_SUN
			end
			-- Not clipped at one: the frame is tone mapped and a voxel in
			-- the sun is well past it, so an object beside one has to be able
			-- to be as well
			return magic.Color(
					(amb.r + sr) * sky + lamp + OBJECT_DARK_FLOOR,
					(amb.g + sg) * sky + lamp + OBJECT_DARK_FLOOR,
					(amb.b + sb) * sky + lamp + OBJECT_DARK_FLOOR)
		end
		local sun = sunlight_color(daylight)
		return magic.Color(
				math.min(1, sun.r * sky + lamp + 0.03),
				math.min(1, sun.g * sky + lamp + 0.03),
				math.min(1, sun.b * sky + lamp + 0.03))
	end

	-- Setting a shader parameter costs a sandbox call, and there are a
	-- hundred objects: only a step the eye can see is worth one.
	local function light_object(entry, x, y, z)
		if not entry.material and not entry.materials then
			return
		end
		local c = object_color(x, y, z, entry.materials ~= nil)
		if not c then
			return
		end
		local key = math.floor(c.r * 32)..","..math.floor(c.g * 32)..","..
				math.floor(c.b * 32)
		if key == entry.light_key then
			return
		end
		entry.light_key = key
		if entry.materials then
			-- A cube of tiles has one material per face
			for _, material in ipairs(entry.materials) do
				material:SetShaderParameter("MatDiffColor", c)
			end
			return
		end
		entry.material:SetShaderParameter("MatDiffColor", c)
	end

	local SPRITE_VISUALS, build_item_cube, object_template =
			world_object_meshes(self, magic, scene, game_texture,
			pbr and magic.cache:GetResource("Technique",
			"luanti_client/res/PBRLitAlphaMask.xml") or object_technique,
			texture)

	-- What an object is drawn as.
	--
	-- simplified: an object whose visual is a mesh this can read is drawn as
	-- that mesh in its rest pose -- BONE, KEYS and ANIM are not read, so a
	-- mob stands still -- a sprite visual is a billboard, and everything
	-- else is a box with the object's first texture on it. A box wearing a
	-- cow's texture reads as a cow where nothing at all reads as nothing at
	-- all, which is what the models Urho3D cannot read fall back to.
	--
	-- obj is what objects.lua parsed; resource(obj) says what it is drawn
	-- wearing, as a resource name, or nil for an object whose texture is not
	-- there yet, and as the six tiles of a node or the quads of a model when
	-- it is one of those.
	function self:set_object(obj, resource)
		local props = obj.props
		-- An item that is a node comes back with the six tiles it is drawn
		-- with as well; then it is a small cube of them rather than a
		-- picture of one
		local own, tiles, mesh = resource(obj)
		local cube = tiles ~= nil
		local meshed = not cube and mesh ~= nil
		local sprite = not cube and not meshed and props ~= nil and
				SPRITE_VISUALS[props.visual] or false
		local entry = object_nodes[obj.id]
		-- A visual that changed changes which component draws it
		if entry and (entry.sprite ~= sprite or entry.cube ~= cube or
				entry.meshed ~= meshed) then
			scene:RemoveChild(entry.node)
			entry = nil
			object_nodes[obj.id] = nil
		end
		if not entry then
			-- A mesh is a copy of its kind's template, which carries the
			-- geometry and the materials already; everything else is built
			-- on a node of its own
			local template = meshed and object_template(mesh) or nil
			local node = template and template.node:Clone() or
					scene:CreateChild("object_"..obj.id)
			entry = {node = node, sprite = sprite, cube = cube,
					meshed = meshed}
			if template then
				node.enabled = true
				entry.textured = true
				entry.materials = template.materials
				entry.model = node:GetComponent("CustomGeometry")
				-- The clone's own materials: a Material made in Lua has no
				-- resource name, so it is not an attribute Urho3D can copy
				for i = 1, #template.materials do
					entry.model:SetMaterial(i - 1, template.materials[i])
				end
			elseif cube then
				entry.model, entry.materials = build_item_cube(node, tiles)
				entry.textured = true
			elseif sprite then
				local set = node:CreateComponent("BillboardSet")
				set.numBillboards = 1
				-- Turned about Y only: a sprite that also leans back when
				-- the camera looks down does not read as standing in the
				-- world
				set.faceCameraMode = magic.FC_ROTATE_Y
				set.castShadows = false
				set.sorted = true
				local billboard = set:GetBillboard(0)
				billboard.position = magic.Vector3(0, 0, 0)
				billboard.enabled = true
				set:Commit()
				entry.model = set
				entry.billboard = billboard
			else
				local model = node:CreateComponent("StaticModel")
				model:SetModel(box_model)
				model.castShadows = false
				entry.model = model
			end
			object_nodes[obj.id] = entry
		end
		-- Where it is and how big: the object's collision box, which is in
		-- nodes and is not centred on the object's own position
		local sx, sy, sz = 0.6, 1.8, 0.6
		local cy = 0.9
		if props and props.collision_min and props.collision_max then
			sx = math.max(0.05, props.collision_max[1] - props.collision_min[1])
			sy = math.max(0.05, props.collision_max[2] - props.collision_min[2])
			sz = math.max(0.05, props.collision_max[3] - props.collision_min[3])
			cy = (props.collision_max[2] + props.collision_min[2]) / 2
		end
		-- Only the stand-in box is centred on its collision box: Luanti
		-- draws a model, a sprite and a cube at the position itself, and
		-- the selection box is about that ([OBJECT_SELECTION_BOX])
		if cube or meshed or sprite then cy = 0 end
		entry.offset = cy
		if cube then
			-- Drawn at the size the object asked for rather than at what
			-- it collides with, the same as a sprite. visual_size is what
			-- Luanti scales the item mesh by, and a dropped node comes out
			-- at about a third of a node, which is what its 0.4 is.
			--
			-- simplified: Luanti's own chain to a final size runs through
			-- the wield mesh's own scale factors; this takes visual_size as
			-- it is, which lands in the same place for a dropped node.
			local v = props and props.visual_size or nil
			entry.node.scale = magic.Vector3(
					math.max(0.05, v and v[1] or 1),
					math.max(0.05, v and v[2] or 1),
					math.max(0.05, v and v[3] or v and v[1] or 1))
			-- How fast it turns, in degrees a second; automatic_rotate is
			-- radians a second
			entry.spin = (props and props.automatic_rotate or 0) *
					180 / math.pi
		elseif meshed then
			-- A model is drawn at the size the object asked for, the same as
			-- a sprite: what it collides with is not what it looks like.
			--
			-- An object's model is authored in Luanti's own scene units,
			-- where a node is ten across, and visual_size scales it in those.
			-- Everything here is in nodes, so the tenth is the conversion. A
			-- node's "mesh" drawtype is the other way round -- authored one
			-- unit to the node -- which is why shapes.lua does not do this.
			local v = props and props.visual_size or nil
			local to_nodes = 1 / 10
			entry.node.scale = magic.Vector3(
					math.max(0.005, (v and v[1] or 1) * to_nodes),
					math.max(0.005, (v and v[2] or 1) * to_nodes),
					math.max(0.005, (v and v[3] or v and v[1] or 1) *
							to_nodes))
		elseif sprite then
			-- A billboard is sized by itself, and by what the object asked
			-- for rather than by what it collides with: a dropped item's
			-- collision box is a whole node and its picture is not
			local w = props.visual_size and props.visual_size[1] or 1
			local h = props.visual_size and props.visual_size[2] or 1
			entry.node.scale = magic.Vector3(1, 1, 1)
			entry.billboard.size = magic.Vector2(math.max(0.05, w) / 2,
					math.max(0.05, h) / 2)
			entry.model:Commit()
		else
			entry.node.scale = magic.Vector3(sx, sy, sz)
		end
		entry.node.position = magic.Vector3(obj.position[1],
				obj.position[2] + cy, obj.position[3])
		entry.at_x, entry.at_y, entry.at_z = obj.position[1], obj.position[2],
				obj.position[3]
		-- A cube of its own is turned by its spin below and by nothing else
		if not entry.spin or entry.spin == 0 then
			entry.node.rotation = magic.Quaternion(0, -(obj.yaw or 0), 0)
			entry.at_yaw = obj.yaw or 0
		end
		entry.lit_at = daylight and math.floor(daylight * 256)
		light_object(entry, obj.position[1], obj.position[2], obj.position[3])

		-- Cleared whatever the object is drawn as: a cube's tiles go on
		-- once, and a flag left set would rebuild it every frame
		local was_stale = obj.visual_stale
		obj.visual_stale = false
		if not cube and not meshed and (was_stale or not entry.textured) then
			-- An object whose texture is not there yet wears the placeholder
			-- rather than nothing: a box with no material at all is drawn
			-- flat white, which reads as a hole in the world
			local name = own or (not entry.material and texture)
			if name then
				local material = magic.Material.new()
				material:SetTechnique(0, object_technique)
				material:SetTexture(0, game_texture(name))
				entry.model.material = material
				entry.material = material
				entry.light_key = nil
				-- The placeholder does not count as textured: the object's
				-- own texture may still turn up
				entry.textured = own ~= nil
			end
		end
	end

	-- A particle's light ([VANILLA_WEATHER] 5), as vanilla's: its
	-- emitter's, as an object's; full glow is a light, white, and on pbr the
	-- lightning's flash radiance, so that it shows over the exposure.
	local function particle_light(x, y, z, glow)
		if (glow or 0) >= sky_model.GLOW_FULL then
			local f = pbr and sky_model.flash_radiance() or 1
			return magic.Color(f, f, f, 1)
		end
		return object_color(x, y, z, false, glow)
	end
	local function solid_at(x, y, z)
		local id = self:node_at(x, y, z)
		if id == nil or not self.node_solid then
			return nil
		end
		return self.node_solid[id] == true
	end
	world_particles(self, magic, log, scene, camera_node, game_texture,
			particle_technique, particles, particle_light, solid_at)

	function self:remove_object(id)
		local entry = object_nodes[id]
		if entry then
			scene:RemoveChild(entry.node)
			object_nodes[id] = nil
		end
	end

	-- Moves the objects' scene nodes to where they are now
	-- Where every object is, once a frame.
	--
	-- Each of these writes is a sandbox call and there are a hundred objects,
	-- which is milliseconds a frame if they all get written; most of them are
	-- standing still at any one time, so what has not moved is left alone.
	-- The light an object is drawn in only changes when it moves or when the
	-- day does.
	-- Where the player's own model stands and which way it faces while a
	-- third-person view is on ([BOX_PLAYTEST_4] 4, 5): the client's own
	-- feet and look, since the server's echo of them is a round trip old
	-- and its yaw is never the local player's. Set by init.lua per frame.
	self.self_pose = nil

	function self:place_objects(objects, dtime)
		local day_step = daylight and math.floor(daylight * 256)
		for id, obj in pairs(objects) do
			local entry = object_nodes[id]
			-- The player's own object carries no position from the server
			-- (it is the client's own), so it is placed from self_pose
			-- alone ([BOX_PLAYTEST_4] 4, 5): before that it stood wherever
			-- it was built -- at the camera -- and filled a third-person
			-- frame with itself
			if entry and (obj.position or (obj.is_self and self.self_pose)) then
				local p = obj.position or {0, 0, 0}
				local x, y, z = p[1], p[2], p[3]
				local yaw = obj.yaw or 0
				if obj.is_self and self.self_pose then
					x, y, z = self.self_pose[1], self.self_pose[2],
							self.self_pose[3]
					yaw = -self.self_pose[4]
					-- Marked so that camera_report() can find it
					entry.is_self_node = true
				end
				if x ~= entry.at_x or y ~= entry.at_y or z ~= entry.at_z then
					entry.at_x, entry.at_y, entry.at_z = x, y, z
					entry.node.position = magic.Vector3(x,
							y + (entry.offset or 0), z)
					-- Its light is its node's (object_color()), so a move
					-- within the node keeps it
					local nx, ny, nz = math.floor(x + 0.5),
							math.floor(y + 0.5), math.floor(z + 0.5)
					if nx ~= entry.lit_x or ny ~= entry.lit_y or
							nz ~= entry.lit_z then
						entry.lit_x, entry.lit_y, entry.lit_z = nx, ny, nz
						entry.lit_at = nil
					end
				end
				if entry.spin and entry.spin ~= 0 and dtime then
					-- A dropped node turns on the spot; the server sends no
					-- yaw for it, so this is the only thing that moves it
					entry.at_yaw = (entry.at_yaw or 0) +
							entry.spin * dtime
					entry.node.rotation = magic.Quaternion(0,
							entry.at_yaw % 360, 0)
				elseif yaw ~= entry.at_yaw then
					entry.at_yaw = yaw
					entry.node.rotation = magic.Quaternion(0, -yaw, 0)
				end
				-- By a step of the daylight rather than its every move:
				-- it eases each frame, and light_object() keeps only a
				-- 1/32 step of the colour anyway
				if entry.lit_at ~= day_step then
					entry.lit_at = day_step
					light_object(entry, x, y, z)
				end
			end
		end
	end

	function self:object_count()
		local n = 0
		for _, _ in pairs(object_nodes) do
			n = n + 1
		end
		return n
	end

	-- Shows the outline on a node, or hides it when there is nothing pointed
	-- at. above is which way the face points.
	-- Which voxel the frame is around. above is which side of it the ray
	-- came in through, which the frame does not care about any more; it is
	-- still taken so that "nothing is pointed at" is one call.
	-- The box to outline when a node is pointed at, in the node's own
	-- -0.5...0.5 coordinates as {x0, y0, z0, x1, y1, z1}, or nil for a node
	-- that is outlined as a whole voxel.
	--
	-- simplified: a node whose selection is several boxes -- a fence with its
	-- rails, a plant with its stem -- gets the one box around all of them,
	-- where Luanti draws each of them.
	function self:selection_at(x, y, z)
		local id = self:node_at(x, y, z)
		local entry = id and self.node_selection and self.node_selection[id]
		if not entry then
			return nil
		end
		local boxes = entry.boxes
		-- The boxes turn with the voxel, the same way its shape does
		local facedir = entry.facing and shapes.facedir_of(
				entry.facing, param2_at(x, y, z)) or nil
		if facedir and facedir ~= 0 then
			entry.turned = entry.turned or {}
			if not entry.turned[facedir] then
				entry.turned[facedir] = turn_boxes(entry.boxes, facedir)
			end
			boxes = entry.turned[facedir]
		end
		local out = {boxes[1][1], boxes[1][2], boxes[1][3],
				boxes[1][4], boxes[1][5], boxes[1][6]}
		for i = 2, #boxes do
			local b = boxes[i]
			for k = 1, 3 do
				if b[k] < out[k] then out[k] = b[k] end
				if b[k + 3] > out[k + 3] then out[k + 3] = b[k + 3] end
			end
		end
		return out
	end

	function self:set_pointed(under, above)
		if not under or not above then
			pointed_node.enabled = false
			return
		end
		local box = self:selection_at(under[1], under[2], under[3])
		if box then
			self:set_pointed_box(
					{under[1] + box[1], under[2] + box[2], under[3] + box[3]},
					{under[1] + box[4], under[2] + box[5], under[3] + box[6]})
			return
		end
		pointed_node.scale = magic.Vector3(1, 1, 1)
		pointed_node.position = magic.Vector3(under[1], under[2], under[3])
		pointed_node.enabled = true
	end

	-- The same outline around an arbitrary box, given in world coordinates,
	-- which is what a pointed object wants.
	--
	-- simplified: the frame is the voxel one scaled, so its bars are
	-- thicker on a big box and thinner on a small one.
	function self:set_pointed_box(min, max)
		if not min or not max then
			pointed_node.enabled = false
			return
		end
		local sx = math.max(0.05, max[1] - min[1])
		local sy = math.max(0.05, max[2] - min[2])
		local sz = math.max(0.05, max[3] - min[3])
		pointed_node.scale = magic.Vector3(sx, sy, sz)
		pointed_node.position = magic.Vector3((min[1] + max[1]) / 2,
				(min[2] + max[2]) / 2, (min[3] + max[3]) / 2)
		pointed_node.enabled = true
	end

	-- The blocks whose light a node change may have moved, waiting to be
	-- asked for again; see set_node() below and refresh_wanted().
	local refresh = {}
	-- Where the camera is, for deciding which of those are worth asking for
	local camera_at = nil
	-- How far away a block can be and still be worth a resend, in blocks.
	-- Asking for a block again costs the server a send, and on a busy server
	-- other players' digging is a constant stream of node changes: what is
	-- gained is the light of what the player is looking at, and beyond a few
	-- blocks that is not worth taking sends away from the map that has not
	-- arrived yet.
	local REFRESH_RANGE_BLOCKS = 3
	-- And a cap on how many are ever waiting. A storm of changes -- a
	-- thousand nodes at once, which a game's own bulk edits do -- leaves the
	-- light stale rather than the world unsent.
	local REFRESH_MAX = 24

	-- Whether a node changing from one id to another can move the light
	-- around it: only a change in what a node gives or in what it lets
	-- through can. A rail replaced by air is neither.
	local function light_changed(from, to)
		if from == to then
			return false
		end
		local lights = self.node_light or {}
		local through = self.node_light_through or {}
		local from_light = lights[from] and lights[from].level or 0
		local to_light = lights[to] and lights[to].level or 0
		if from_light ~= to_light then
			return true
		end
		-- A node the definitions do not cover is drawn as a placeholder
		-- cube, which is what it blocks light as
		local from_through = through[from]
		local to_through = through[to]
		if from_through == nil then from_through = false end
		if to_through == nil then to_through = false end
		return from_through ~= to_through
	end

	-- The light around a node change, worked out here rather than asked for
	-- again; light.lua is the algorithm and this is what it reads and
	-- writes. The writes are held until the flood is done and then go into
	-- each block in one pass, because a block's param1 is a string and
	-- rebuilding it once per node would be thousands of copies of four
	-- kilobytes. The reads see the writes, so the flood sees its own work.
	local light_writes = {}
	local light_dirty = {}

	local function light_index(x, y, z)
		local bx = math.floor(x / BLOCKSIZE)
		local by = math.floor(y / BLOCKSIZE)
		local bz = math.floor(z / BLOCKSIZE)
		return block_key(bx, by, bz),
				(x - bx * BLOCKSIZE) +
				(y - by * BLOCKSIZE) * BLOCKSIZE +
				(z - bz * BLOCKSIZE) * BLOCKSIZE * BLOCKSIZE,
				bx, by, bz
	end

	local light_access = {
		node = function(x, y, z)
			return self:node_at(x, y, z)
		end,
		light = function(x, y, z)
			local key, i = light_index(x, y, z)
			local writes = light_writes[key]
			local p = writes and writes[i]
			if p == nil then
				p = param1_at(x, y, z)
			end
			if p == nil then
				return nil
			end
			return p % 16, math.floor(p / 16)
		end,
		set_light = function(x, y, z, day, night)
			local key, i, bx, by, bz = light_index(x, y, z)
			if not blocks[key] then
				return
			end
			local writes = light_writes[key]
			if not writes then
				writes = {}
				light_writes[key] = writes
			end
			writes[i] = (day % 16) + (night % 16) * 16
			light_dirty[key] = true
			-- A node on a block's edge is in the neighbour's border, so
			-- that mesh is out of date as well
			local lx = x - bx * BLOCKSIZE
			local ly = y - by * BLOCKSIZE
			local lz = z - bz * BLOCKSIZE
			for _, d in ipairs(NEIGHBOURS) do
				if (d[1] < 0 and lx == 0) or
						(d[1] > 0 and lx == BLOCKSIZE - 1) or
						(d[2] < 0 and ly == 0) or
						(d[2] > 0 and ly == BLOCKSIZE - 1) or
						(d[3] < 0 and lz == 0) or
						(d[3] > 0 and lz == BLOCKSIZE - 1) then
					light_dirty[block_key(bx + d[1], by + d[2],
							bz + d[3])] = true
				end
			end
		end,
		source = function(id)
			local entry = self.node_light and self.node_light[id]
			return entry and entry.level or 0
		end,
		through = function(id)
			return (self.node_light_through or {})[id] == true
		end,
		sun_through = function(id)
			return (self.node_sun_through or {})[id] == true
		end,
	}

	-- The light of everything around one node that changed. What comes back
	-- is whether anything was left unresolved -- a node in a block we do not
	-- have, or the flood running out of budget -- which is when asking the
	-- server for the block is still worth it.
	local function flood_light(x, y, z, from_id, to_id, old_param1)
		local visited, unresolved = light_flood.update(light_access,
				x, y, z, from_id, to_id,
				old_param1 % 16, math.floor(old_param1 / 16))
		for key, writes in pairs(light_writes) do
			local block = blocks[key]
			if block then
				-- One pass over the string per block: the pieces between
				-- the writes, with the new bytes between them
				local indices = {}
				for i in pairs(writes) do
					indices[#indices + 1] = i
				end
				table.sort(indices)
				local parts = {}
				local last = 0
				for _, i in ipairs(indices) do
					parts[#parts + 1] = block.param1:sub(last + 1, i)
					parts[#parts + 1] = string.char(writes[i])
					last = i + 1
				end
				parts[#parts + 1] = block.param1:sub(last + 1)
				block.param1 = table.concat(parts)
			end
			light_writes[key] = nil
		end
		for key in pairs(light_dirty) do
			if blocks[key] then
				mark_dirty(key)
			end
			light_dirty[key] = nil
		end
		return visited, unresolved
	end

	-- One node the server changed, in node coordinates. Patches the block's
	-- parameter arrays in place; a node on a block's edge is part of the
	-- neighbour's border, so that mesh goes out of date too.
	-- param1 may be nil, which means the node became air and its light has
	-- to be worked out here.
	--
	-- The light of everything *around* the node is worked out here, the way
	-- Luanti's own client works it out: take away the light that came from
	-- what changed and spread what is left back in. See light.lua. What that
	-- cannot finish -- a node in a block we do not have, or a flood that ran
	-- out of budget -- falls back to asking the server for the block again.
	function self:set_node(x, y, z, param0, param1, param2)
		param1 = param1 or removal_light(x, y, z)
		param2 = param2 or 0
		local bx = math.floor(x / BLOCKSIZE)
		local by = math.floor(y / BLOCKSIZE)
		local bz = math.floor(z / BLOCKSIZE)
		local key = block_key(bx, by, bz)
		local block = blocks[key]
		if not block then
			return false -- Not a block we are drawing
		end
		local lx = x - bx * BLOCKSIZE
		local ly = y - by * BLOCKSIZE
		local lz = z - bz * BLOCKSIZE
		local i = lx + ly * BLOCKSIZE + lz * BLOCKSIZE * BLOCKSIZE
		-- What was there, for the light: see light_changed() and
		-- flood_light() above
		local was = block.param0:byte(i * 2 + 1) * 256 +
				block.param0:byte(i * 2 + 2)
		local was_param1 = block.param1:byte(i + 1) or 0
		block.param0 = block.param0:sub(1, i * 2)..
				string.char(math.floor(param0 / 256) % 256, param0 % 256)..
				block.param0:sub(i * 2 + 3)
		block.param1 = block.param1:sub(1, i)..string.char(param1 % 256)..
				block.param1:sub(i + 2)
		block.lights = nil -- One of its voxels may have been a light
		if block.param2 then
			block.param2 = block.param2:sub(1, i)..
					string.char(param2 % 256)..block.param2:sub(i + 2)
			-- What it looks like may be a pair that has no voxel id yet
			if build_pair then
				local entry = param2_look[param0]
				local key = param0 + (param2 % 256) * PAIR_SCALE
				if entry and self.pair_map[key] == nil then
					build_pair(entry, param0, param2 % 256, key)
				end
			end
		end
		mark_dirty(key)
		for _, d in ipairs(NEIGHBOURS) do
			-- Only the neighbour the node is up against sees it in its border
			if (d[1] < 0 and lx == 0) or (d[1] > 0 and lx == BLOCKSIZE - 1) or
					(d[2] < 0 and ly == 0) or
					(d[2] > 0 and ly == BLOCKSIZE - 1) or
					(d[3] < 0 and lz == 0) or
					(d[3] > 0 and lz == BLOCKSIZE - 1) then
				mark_dirty(block_key(bx + d[1], by + d[2], bz + d[3]))
			end
		end
		if light_changed(was, param0) then
			local visited, unresolved = flood_light(x, y, z, was, param0,
					was_param1)
			self.last_light_visited = visited
			if unresolved then
				-- The flood ran into a block we do not have, or out of
				-- budget: the server's own light is the way out, and it
				-- sends a block again when we say we no longer have it
				local waiting = 0
				for _ in pairs(refresh) do
					waiting = waiting + 1
				end
				if waiting < REFRESH_MAX then
					refresh[key] = {bx, by, bz}
				end
			end
		end
		return true
	end

	-- The blocks to ask the server for again, at most a handful at a time:
	-- one node change can name seven blocks and a spree of them more than a
	-- packet holds. What is left waits for the next call, and what is too
	-- far from the camera is dropped rather than waited for.
	function self:refresh_wanted(limit)
		local out = {}
		local cx, cy, cz = 0, 0, 0
		if camera_at then
			cx = math.floor(camera_at[1] / BLOCKSIZE)
			cy = math.floor(camera_at[2] / BLOCKSIZE)
			cz = math.floor(camera_at[3] / BLOCKSIZE)
		end
		for key, at in pairs(refresh) do
			refresh[key] = nil
			local near = camera_at == nil or
					(math.abs(at[1] - cx) <= REFRESH_RANGE_BLOCKS and
					math.abs(at[2] - cy) <= REFRESH_RANGE_BLOCKS and
					math.abs(at[3] - cz) <= REFRESH_RANGE_BLOCKS)
			if near then
				out[#out + 1] = at
				if #out >= (limit or 8) then
					break
				end
			end
		end
		return out
	end

	-- The colour of the sky, for a day/night factor of 0...1. This is the one
	-- thing that moves the sun: the mesher put how much of the sky each
	-- surface sees into its vertex colours, and the shader multiplies that by
	-- the zone's ambient colour.
	-- Luanti's own default sky colours, from its skyparams.h. A game that
	-- says its own replaces them, and this one does.
	local SKY_DEFAULT = {
		day_sky = {97, 181, 245},
		day_horizon = {144, 211, 246},
		dawn_sky = {180, 186, 250},
		dawn_horizon = {186, 193, 240},
		night_sky = {0, 107, 255},
		night_horizon = {64, 144, 255},
		indoors = {100, 100, 100},
		sun_tint = {244, 125, 29},
		moon_tint = {127, 153, 204},
	}


	-- The sun's own colour at noon. Luanti's sunlight_color() is the colour
	-- of the sun and the sky together, because together is the only way
	-- Luanti has them; on the PBR path the sky is a light of its own, so what
	-- is left for the sun is what the sun is. Only a little warm: what makes
	-- sunlight read as golden is the blue ambient beside it, and a light
	-- warmer than this shows up undisguised in what a glint reflects.
	-- apps/sample_lighting_scene's sun is the same colour.
	local SUN_COLOR = {1.0, 0.96, 0.88}
	-- And how much of the sun's colour the clouds take while it is down
	-- there. More than the light itself takes, because a cloud at dawn is
	-- lit by nothing else and the sun is lighting it from below, where the
	-- ground is lit by the sky as well.
	local CLOUD_SUN_TINT = 0.75

	-- One of the game's colours, or Luanti's default for it, as 0...1
	local function sky_color(name, brightness)
		local c = (sky and sky[name]) or SKY_DEFAULT[name]
		if not c then
			return magic.Color(0, 0, 0)
		end
		local b = brightness or 1
		return magic.Color(c[1] / 255 * b, c[2] / 255 * b, c[3] / 255 * b)
	end

	-- How light it is, from the day/night ratio. Luanti runs the ratio
	-- through its light curve (decode_light_f) to get this; a gamma of 2.2 is
	-- the same shape without the table -- 1 stays 1, the 0.175 the ramp
	-- bottoms out at comes to about 0.02.
	local function brightness_of(factor)
		return factor ^ 2.2
	end

	-- How much of the sky is cloud and what a body's light is through it:
	-- res/sky_model.lua's weather, one rule for both clients
	-- ([VANILLA_WEATHER]). The colour arrives 0..255 with its alpha.
	local function cloud_rgb()
		local c = (sky_bodies.clouds or {}).color_bright
		return c and {r = c[1] / 255, g = c[2] / 255, b = c[3] / 255} or nil
	end
	local metered_cover = nil
	local function cloud_cover()
		local clouds = sky_bodies.clouds or {}
		return sky_model.cloud_cover(clouds.density, cloud_rgb(),
				not (sky and sky.clouds == false))
	end
	local function direct_light(body)
		return sky_model.direct_light(not body or body.visible ~= false,
				cloud_cover())
	end

	-- What the sun shines with now: its own colour, going the colour of the
	-- horizon over the hour it is crossing it, which is where that colour
	-- belongs and is the same handover the sky shader does to the disc.
	local function sun_light_color(time_of_day)
		local tint = sky_color("sun_tint", 1)
		local low = sky_model.sun_tint_share(time_of_day)
		return magic.Color(
				SUN_COLOR[1] * (1 - low) + tint.r * low,
				SUN_COLOR[2] * (1 - low) + tint.g * low,
				SUN_COLOR[3] * (1 - low) + tint.b * low)
	end

	-- That a quarter of an hour off the horizon (05:00, 19:00) the light is
	-- red rather than a warm white, which is the whole of what the window is
	-- for
	do
		local setting = sun_light_color(19000 - 250)
		assert(setting.r - setting.b > 0.5, "a quarter hour from setting")
		local rising = sun_light_color(5000 + 250)
		assert(rising.r - rising.b > 0.5, "and a quarter hour after rising")
		local noon = sun_light_color(12000)
		assert(noon.r - noon.b < 0.15, "and its own colour the rest of the day")
	end

	-- Luanti eases the sky rather than setting it: Sky::update() keeps the
	-- colours and the brightness it is drawing and moves each a fixed share
	-- of the way to the target every frame, so a band changing under it comes
	-- out as a minute of sunrise instead of a jump. The same thing here, with
	-- the share worked out from the frame's own length so that it does not
	-- depend on how fast the frames come, and with a jump too big to be the
	-- day moving -- a game setting its clock, or a sky arriving -- taken at
	-- once rather than eased, which is Luanti's rule as well.
	local SKY_EASE_SECONDS = 0.8
	local SKY_EASE_SNAP = 0.35

	local sky_eased = {}
	-- When apply_daylight() last set the sky's parameters that only the
	-- game changes; nil when it has changed them
	local sky_static_at = nil

	local function sky_share(dtime)
		if dtime <= 0 then
			return 1
		end
		-- 1 - e^-t/tau, but without exp: this is within a few per cent of it
		-- over a frame and cannot overshoot
		return clamp01(dtime / (SKY_EASE_SECONDS + dtime))
	end

	local function sky_ease(dtime, key, target)
		local at = sky_eased[key]
		if at == nil or math.abs(target - at) > SKY_EASE_SNAP then
			sky_eased[key] = target
			return target
		end
		at = at + (target - at) * sky_share(dtime)
		sky_eased[key] = at
		return at
	end

	-- The same for a colour, eased in the band's own full-strength colours
	-- and scaled by the brightness afterwards, so that what is being eased is
	-- which sky it is rather than how dark it is
	local function sky_ease_color(dtime, key, target, brightness)
		local at = sky_eased[key]
		if at == nil or math.abs(target.r - at[1]) > SKY_EASE_SNAP or
				math.abs(target.g - at[2]) > SKY_EASE_SNAP or
				math.abs(target.b - at[3]) > SKY_EASE_SNAP then
			at = {target.r, target.g, target.b}
			sky_eased[key] = at
		else
			local k = sky_share(dtime)
			at[1] = at[1] + (target.r - at[1]) * k
			at[2] = at[2] + (target.g - at[2]) * k
			at[3] = at[3] + (target.b - at[3]) * k
		end
		return magic.Color(at[1] * brightness, at[2] * brightness,
				at[3] * brightness)
	end

	-- What the easing has to do, checked at load: arrive where it was sent,
	-- take its time getting there, and not take its time over a jump that is
	-- a game setting its clock rather than the day passing.
	do
		assert(sky_ease(0.1, "check", 0.5) == 0.5, "the first is where it is")
		local half = sky_ease(SKY_EASE_SECONDS, "check", 0.7)
		assert(half > 0.58 and half < 0.62,
				"a tau of it is about half the way")
		for _ = 1, 200 do
			sky_ease(0.05, "check", 0.7)
		end
		assert(math.abs(sky_ease(0.05, "check", 0.7) - 0.7) < 0.001,
				"and it arrives")
		assert(sky_ease(0.05, "check", 0.0) == 0.0, "a jump is taken at once")
		sky_eased.check = nil
	end

	local function apply_daylight(dtime)
		local factor = daylight
		if not pbr then
			zone.ambientColor = sunlight_color(factor)
		end

		local brightness = brightness_of(factor)
		-- Which set of colours, by the same bands Luanti's Sky::update()
		-- uses: night, dawn, or the day's own. The set changes at a step,
		-- there as here; what makes the change not read as one is that
		-- nothing below is the target, it is where the sky has got to on its
		-- way there. See sky_ease() above.
		--
		-- simplified: Luanti has a fourth set for a player who cannot see the
		-- sky at all, which is not read here.
		local band = "day"
		if brightness < 0.13 then
			band = "night"
		elseif brightness >= 0.20 and brightness < 0.35 then
			band = "dawn"
		end
		local top = sky_color(band.."_sky", 1)
		local horizon = sky_color(band.."_horizon", 1)
		if pbr and band == "day" then
			-- The day's hue is the render's on pbr, a game's own day colours
			-- being display colours for Luanti's sky (vanilla does the same)
			top = magic.Color(PHYS.day_zenith.r, PHYS.day_zenith.g,
					PHYS.day_zenith.b)
			horizon = magic.Color(PHYS.day_horizon.r, PHYS.day_horizon.g,
					PHYS.day_horizon.b)
		end
		if sky and sky.type == "skybox" then
			-- A game that gave its own textures gets its bgcolor, which is
			-- the one thing of its sky that is understood here
			top = sky_color("bgcolor", 1)
			horizon = top
		elseif sky and not sky.day_sky and sky.bgcolor then
			top = sky_color("bgcolor", 1)
			horizon = top
		end

		-- Where the sky has actually got to, which is what everything below
		-- is drawn from. The brightness the band is scaled by is eased too,
		-- so a sunrise is a sunrise and not a set of colours being swapped.
		brightness = sky_ease(dtime, "brightness", brightness)
		top = sky_ease_color(dtime, "top", top, brightness)
		horizon = sky_ease_color(dtime, "horizon", horizon, brightness)

		-- What is behind the world, which the fog fades into: the horizon
		-- the sky is drawn with, so the two meet
		zone.fogColor = horizon

		-- On the PBR path the sky is drawn at its radiance and the ambient
		-- light is that sky (physical_sky above). The shader's ambient is
		-- cAmbientColor.rgb * color.a + color.rgb, so what a surface gets is
		-- the sky in proportion to how much of it it can see, and a cave is
		-- only the warm rgb the torches baked in. The fog is the horizon the
		-- sky meets the ground with.
		local _, height = sun_direction(daylight_time)
		local sky_top, sky_horizon = top, horizon
		local ambient
		if pbr then
			sky_top, sky_horizon, ambient =
					physical_sky(top, horizon, height)
		end
		-- Under cover the sky goes the clouds' colour, the horizon and the
		-- fog a third of the zenith (res/sky_model.lua's overcast); on pbr,
		-- where the game's darker colours are not drawn, the zenith dims
		-- too, and the ambient, the dome's mean, with the two
		local cover = cloud_cover()
		if cover > 0 then
			local z, h = sky_model.overcast(sky_top, sky_horizon, cloud_rgb(),
					cover, pbr and sky_model.OVERCAST_DIM or 0)
			if ambient then
				local function dome(a, b)
					return luminance({5 * a.r + b.r, 5 * a.g + b.g,
							5 * a.b + b.b})
				end
				local k = dome(z, h) / math.max(dome(sky_top, sky_horizon),
						1e-9)
				ambient = magic.Color(ambient.r * k, ambient.g * k,
						ambient.b * k)
			end
			sky_top = magic.Color(z.r, z.g, z.b)
			sky_horizon = magic.Color(h.r, h.g, h.b)
		end
		-- A white sky is the lightning's layer (VoxeLibre's, for 0.1 s):
		-- the game's colour as it is, not eased, and on pbr at the flash's
		-- radiance (res/sky_model.lua's sky_flash)
		local flash = sky_model.sky_flash(sky and sky[band.."_sky"] and
				sky_color(band.."_sky", 1))
		if flash > 0 then
			local f = pbr and sky_model.flash_radiance() or 1
			local function lit(c)
				return magic.Color(c.r + (f - c.r) * flash,
						c.g + (f - c.g) * flash, c.b + (f - c.b) * flash)
			end
			sky_top, sky_horizon = lit(sky_top), lit(sky_horizon)
		end
		zone.fogColor = sky_horizon
		if ambient then
			zone.ambientColor = ambient
		end
		-- And the meter, which would put a storm at a clear day's brightness
		if pbr and metered_cover ~= cover then
			local vp = magic.renderer:GetViewport(0)
			if vp and vp.renderPath then
				metered_cover = cover
				vp.renderPath:SetShaderParameter("AutoExposureMiddleGrey",
						sky_model.middle_grey(0.18, cover))
			end
		end

		-- What the PBR path's reflections are multiplied by: one, the cube
		-- map being the sky drawn at this hour already (sky_cube), which
		-- carries the night itself
		if vis then
			vis:set_param("SkyColor", magic.Vector3(1, 1, 1))
		end

		if sun_light then
			-- The light travels the other way from the body it comes from,
			-- and the moon is opposite the sun, so one direction gives both.
			-- Whichever of the two is under the world is taken out of the
			-- scene rather than dimmed: a directional light does not know
			-- about the horizon, and one below it lights the undersides of
			-- everything and puts the night's sparkle on the wrong side of
			-- the sky.
			-- Where they are is stepped; whether they are up, how bright
			-- and what colour is not, so nothing about the light itself
			-- steps, only the direction the shadow is cast from
			local sx, sy, sz = sun_direction(stepped_time(daylight_time))
			local _, smooth_sy = sun_direction(daylight_time)
			local sun_lit = direct_light(sky_bodies.sun)
			local up = sun_amount(daylight_time) * above_horizon(smooth_sy) *
					sun_lit
			sun_node.enabled = up > 0
			local sun_color = sun_light_color(daylight_time)
			if pbr then
				-- The sun's irradiance and colour from its elevation; the
				-- fade is in PHYS.sun, the clouds and a hidden sun as above
				sun_color = magic.Color(PHYS.sun_rgb(smooth_sy))
			end
			if up > 0 then
				sun_node.direction = magic.Vector3(-sx, -sy, -sz)
				sun_light.brightness = pbr and UNITS * PHYS.sun(smooth_sy) *
						sun_lit or
						SUN_BRIGHTNESS * up
				sun_light.color = sun_color
			end
			local moon_up = moon_amount(daylight_time) *
					above_horizon(-smooth_sy) * direct_light(sky_bodies.moon)
			moon_node.enabled = moon_up > 0
			if moon_up > 0 then
				moon_node.direction = magic.Vector3(sx, sy, sz)
				moon_light.brightness = (pbr and UNITS * PHYS.moon_e or
						MOON_BRIGHTNESS) * moon_up
				-- And the moon takes the horizon's colour the way the sun
				-- does, on the other side of the sky and at the same hours:
				-- it is crossing the horizon whenever the sun is. Luanti's
				-- fog_moon_tint, which a game sets beside fog_sun_tint and
				-- which this read off the wire and never used; see
				-- [SKY_KNOBS] in doc/plan/rendering_plan.md.
				local tint = sky_color("moon_tint", 1)
				local low = sky_model.sun_tint_share(daylight_time)
				moon_light.color = pbr and PBR_MOON_COLOR or magic.Color(
						MOON_COLOR[1] * (1 - low) + tint.r * low,
						MOON_COLOR[2] * (1 - low) + tint.g * low,
						MOON_COLOR[3] * (1 - low) + tint.b * low)
			end
			-- What the two are worth to something drawn unlit, which has no
			-- normal to take a share of them by: the colour of whichever is
			-- up, and in the alpha how much of it there is, the moon counted
			-- at what it is worth against the sun: a fiftieth, the two
			-- lights' ratio before the sun came down from 50 to 3
			object_sun = magic.Color(sun_color.r, sun_color.g, sun_color.b,
					up + moon_up / 50)
		end

		if sky_material then
			local sx, sy, sz = sun_direction(daylight_time)
			sky_material:SetShaderParameter("SkyTop", sky_top)
			sky_material:SetShaderParameter("SkyHorizon", sky_horizon)
			sky_material:SetShaderParameter("SkyPhysical", pbr and 1 or 0)
			sky_material:SetShaderParameter("SunDirection",
					magic.Vector3(sx, sy, sz))
			-- The tint the sun paints the horizon with, at its own strength
			-- rather than the sky's: it is what dawn and dusk are
			sky_material:SetShaderParameter("SunTint",
					sky_color("sun_tint", 0.35 + brightness * 0.65))
			-- What a direction that cannot see the sky is drawn as: Luanti's
			-- indoors colour, dimmed with the day, mixed by the sky
			-- visibility cube skyvis.lua already keeps. A seam is a place
			-- where the rasteriser shows sky where the voxel data says rock,
			-- so the cube is near zero there by construction and the hole
			-- goes dark without anything having to detect it. See [CAVE_SKY]
			-- in doc/plan/rendering_plan.md.
			--
			-- auto_dim_skybox is the game's switch for this and nothing
			-- else; client.lua reads it off SET_SKY, and a game that says
			-- false keeps its sky undimmed -- the same knob the launcher
			-- turns through set_auto_dim() ([SKY_KNOBS])
			sky_material:SetShaderParameter("SkyIndoors",
					sky_color("indoors", brightness))
			sky_material:SetShaderParameter("SkyAutoDim",
					(sky and sky.auto_dim_skybox == false) and 0.0 or 1.0)
			-- **A parameter a material never sets reads as zero**, and zero
			-- here means "in a cave", which would draw this client's sky as
			-- the indoors colour everywhere. Set to one until this client
			-- computes the scalar for itself; it has the cube that would
			-- give it -- see skyvis.lua -- and the sky is then edited only
			-- once there is no sky to see. [CAVE_SKY].
			sky_material:SetShaderParameter("SkyOutside", 1.0)
			-- Luanti's clouds are the daylight's own colour, unless the
			-- game gave them one; either way they go dark with the day. And
			-- over the hour the sun spends crossing the horizon they take its
			-- colour, because at that hour the sun is what is lighting them
			-- and it is lighting them from underneath: that is what makes a
			-- sunrise a sunrise rather than a sky that has got brighter.
			local sun_now = sun_light_color(daylight_time)
			local lit = low_sun(daylight_time) * CLOUD_SUN_TINT
			local cloud = sky_bodies.clouds.color_bright
			local own = cloud and
					{cloud[1] / 255, cloud[2] / 255, cloud[3] / 255} or
					{0.9, 0.92, 0.95}
			local function cloud_channel(i, from_sun)
				return (own[i] * (1 - lit) + from_sun * lit) * brightness
			end
			if cloud then
				sky_material:SetShaderParameter("CloudColor", magic.Color(
						cloud_channel(1, sun_now.r),
						cloud_channel(2, sun_now.g),
						cloud_channel(3, sun_now.b)))
			else
				sky_material:SetShaderParameter("CloudColor", magic.Color(
						cloud_channel(1, sun_now.r) + 0.05,
						cloud_channel(2, sun_now.g) + 0.05,
						cloud_channel(3, sun_now.b) + 0.06))
			end
			if pbr then
				-- pbr draws the cloud as a reflectance lit by the sun and the
				-- sky, vanilla's ([CLOUD_LIGHT], [DUSK_CLOUD]): the game's
				-- colour the albedo, the sky's share the dome's mean, the
				-- sun's E of the hour times how high it is times k_sun, which
				-- makes a thin noon cloud PHYS.cloud_n times the zenith. The
				-- clouds see the sun PHYS.cloud_dip longer. simplified: no
				-- dusk glow term.
				local noon_mean = (5 * PHYS.sky_zenith + PHYS.sky_horizon) / 6
				local k_sun = math.max(0, (PHYS.cloud_n * PHYS.sky_zenith /
						sky_model.CLOUD_REF_LUM - noon_mean) * math.pi /
						PHYS.sun(1))
				local h = height + PHYS.cloud_dip
				local e = UNITS * PHYS.sun(h) * math.max(h, 0) * k_sun /
						math.pi * direct_light(sky_bodies.sun)
				local r, g, b = PHYS.sun_rgb(h)
				sky_material:SetShaderParameter("CloudSun", magic.Color(
						own[1] * e * r, own[2] * e * g, own[3] * e * b))
				sky_material:SetShaderParameter("CloudSky", magic.Color(
						own[1] * (5 * sky_top.r + sky_horizon.r) / 6,
						own[2] * (5 * sky_top.g + sky_horizon.g) / 6,
						own[3] * (5 * sky_top.b + sky_horizon.b) / 6))
				-- And the sun's disc at its radiance: E of the hour over
				-- the disc's solid angle, in its colour, inside rgba16f
				local half = SUN_HALF * (sky_bodies.sun.scale or 1)
				local disc = math.min(UNITS * PHYS.sun(height) /
						(math.pi * half * half), 65504)
				local sr, sg, sb = PHYS.sun_rgb(height)
				sky_material:SetShaderParameter("SunRadiance",
						magic.Vector3(disc * sr, disc * sg, disc * sb))
			end
			-- The stars come out as the sky goes dark, and a game can say
			-- they are out in the day as well
			local day_opacity = sky_bodies.stars.day_opacity or 0
			sky_material:SetShaderParameter("StarFade", math.max(day_opacity,
					math.max(0, math.min(1, (0.25 - brightness) * 6))))

			-- What the game says is up there, and how much of it: set when
			-- it says something new and once a second besides, for a
			-- texture whose media has arrived since. None of it moves with
			-- the time of day.
			if not sky_static_at or
					scene.elapsedTime >= sky_static_at + 1 then
				sky_static_at = scene.elapsedTime
				local sun = sky_bodies.sun
				local moon = sky_bodies.moon
				local stars = sky_bodies.stars
				-- The textures, if the game gave any and the media has arrived.
				-- A body whose texture is not there wears the shader's own
				-- colour until it is: the sky is drawn from the first frame and
				-- the media comes later.
				local sun_texture = sun.visible and sun.texture and
						sun.texture ~= "" and media_texture and
						media_texture(sun.texture) or nil
				local moon_texture = moon.visible and moon.texture and
						moon.texture ~= "" and media_texture and
						media_texture(moon.texture) or nil
				if sun_texture then
					sky_material:SetTexture(0, game_texture(sun_texture))
				end
				if moon_texture then
					sky_material:SetTexture(1, game_texture(moon_texture))
				end
				sky_material:SetShaderParameter("SunTextured",
						sun_texture and 1 or 0)
				sky_material:SetShaderParameter("MoonTextured",
						moon_texture and 1 or 0)
				-- How far past white the disc is drawn. On the PBR path the
				-- frame is tone mapped, so this is a real multiplier and what
				-- the bloom around the sun comes from; on the vanilla path the
				-- frame clips at one and a little past it is all that is wanted.
				sky_material:SetShaderParameter("SunOverexposure",
						pbr and SUN_DISC_OVEREXPOSURE or 1.5)
				sky_material:SetShaderParameter("SunSize",
						sun.visible and SUN_HALF * (sun.scale or 1) or 0)
				sky_material:SetShaderParameter("MoonSize",
						moon.visible and MOON_HALF * (moon.scale or 1) or 0)
				sky_material:SetShaderParameter("StarDensity",
						stars.visible and STAR_DENSITY_DEFAULT *
						(stars.count or STARS_DEFAULT) / STARS_DEFAULT or 0)
				local star_color = stars.color or {133, 140, 158}
				sky_material:SetShaderParameter("StarColor", magic.Color(
						star_color[1] / 255, star_color[2] / 255,
						star_color[3] / 255))
				-- How fast they drift, which a game changes with the weather
				local wind = sky_bodies.clouds.speed or CLOUD_SPEED_DEFAULT
				sky_material:SetShaderParameter("CloudWind", magic.Vector2(
						wind[1] * CLOUD_WIND_PER_NODE,
						wind[2] * CLOUD_WIND_PER_NODE))
				-- The density goes to the shader as it came. Luanti fills a
				-- cloud cell where its own 0...1 noise falls below the density,
				-- so the number is a quantile of that noise; the shader beside
				-- this file fills where its noise rises above one minus the
				-- coverage, which is a quantile of its own. Both are value noise
				-- of much the same shape and both are even about a half, so the
				-- quantile carries straight across and the coverage is the
				-- density. Sampled over two hundred thousand points, what
				-- Luanti's client covers and what this one covers agree to within
				-- two parts in a hundred the whole way from nothing to a full
				-- sky. What was here before scaled the density by 0.85 first,
				-- which at Luanti's own default covered a sixth of the sky where
				-- Luanti covers a quarter.
				local cloud_color = sky_bodies.clouds.color_bright
				sky_material:SetShaderParameter("CloudAlpha",
						(cloud_color and cloud_color[4] and
						cloud_color[4] / 255) or CLOUD_ALPHA_DEFAULT)
				sky_material:SetShaderParameter("CloudCoverage",
						(sky and sky.clouds == false) and 0 or
						(sky_bodies.clouds.density or CLOUD_DENSITY_DEFAULT))
			end
			-- And the reflections follow, once a second at most: the sun
			-- moves every frame and the cube is six renders
			if sky_cube and scene.elapsedTime >= (self.sky_cube_due or 0) then
				self.sky_cube_due = scene.elapsedTime + 1
				sky_cube:update()
			end
		end
	end

	-- What the light and the time are now. Nothing is drawn from here: the
	-- sky is drawn every frame by apply_daylight(), easing towards whatever
	-- this last said, which is what makes the day pass rather than step.
	-- Where the sun is, as the sine of its elevation: what the pre-dawn
	-- light is measured against ([DAWN_LIGHT]), asked for by the code that
	-- decides the day factor
	function self:sun_height(time_of_day)
		local _, y = sun_direction(time_of_day)
		return y
	end

	function self:set_daylight(factor, time_of_day)
		daylight = factor
		daylight_time = time_of_day or daylight_time
	end

	-- A game's set_lighting() ([VANILLA_WEATHER] 6), flat by
	-- res/sky_model.lua's LIGHTING names: the saturation in every mode,
	-- how dark a shadow is on shadows (pbr's shadow is what the sun does
	-- not reach, as vanilla's); the rest is said once and not drawn.
	local lighting_said = {}
	function self:set_lighting(l)
		local sat = l.saturation or 1
		self.render_path:SetEnabled("Saturation", math.abs(sat - 1) > 1e-6)
		self.render_path:SetShaderParameter("Saturation", sat)
		if mode == "shadows" and l.shadow_intensity then
			local keep = 1 - math.max(0, math.min(1, l.shadow_intensity))
			sun_light.shadowIntensity = keep
			moon_light.shadowIntensity = keep
		end
		for _, n in ipairs(sky_model.lighting_not_drawn(l,
				{saturation = true, shadow_intensity = true})) do
			if not lighting_said[n] then
				lighting_said[n] = true
				log:info("set_lighting: "..n.." is not drawn")
			end
		end
	end

	function self:set_sky(new_sky)
		sky = new_sky
		sky_static_at = nil
		-- Where the fog starts is the game's to say, as a fraction of the
		-- range; 0.7 is this client's own when it says nothing. The
		-- reference fixture says 0.99, which is the fog off. [SKY_KNOBS].
		if zone and type(sky.fog_start) == "number" and sky.fog_start >= 0 then
			zone.fogStart = far_clip * math.min(sky.fog_start, 0.99)
		end
	end

	-- What the game says is in the sky, each out of its own packet. The
	-- fields are the ones client.lua read; what is not there is left as it
	-- was, which is how Luanti treats them too.
	function self:set_sky_body(which, what)
		if not sky_bodies[which] or not what then
			return
		end
		sky_static_at = nil
		for key, value in pairs(what) do
			sky_bodies[which][key] = value
		end
	end

	-- Builds the voxel registry from Luanti's node definitions.
	--
	-- defs is what nodedef.parse() returned. resolve_tile(def, i) turns one of
	-- a node's six faces into a resource name the cache can find, or nil for
	-- one that cannot be built: what a tile is drawn as is the game's own
	-- business -- the texture expression, the overlay, the colour -- and this
	-- only needs the name that comes out. A node with any face unresolved
	-- keeps the placeholder: half a cube's textures is worse to look at than
	-- none of them.
	--
	-- One definition as a voxel in a registry, or nil for one whose textures
	-- are not all there. override is a colour that stands in for the
	-- definition's own, which is what a palette index comes to.
	-- name has to be different for every voxel in a registry: the registry
	-- keys them by it, and adding a second voxel under a name it already has
	-- is an error. A pair's name carries what makes it different.
	--
	-- variants is what the voxel's param2 does to it -- turned one way, its
	-- liquid at one of eight levels -- as build_variants() worked it out.
	-- The voxel itself is built facing 0, with its liquid full, which is what
	-- a param2 that means nothing draws as.
	local function build_voxel(reg, def, resolve_tile, override, name,
			variants)
		local kind = CUBE_DRAWTYPES[def.drawtype]
		local group = liquid_group(def)
		-- What the mesher needs to work out this voxel's connections per
		-- voxel: which family it is in, which families it reaches out to,
		-- and whether it also reaches into a solid neighbour
		local connect = nil
		if (def.connect_group or 0) ~= 0 or (def.connect_mask or 0) ~= 0 then
			connect = {group = def.connect_group, mask = def.connect_mask,
					solid = (def.connect_sides or 0) ~= 0}
		end
		-- Luanti draws a liquid from its *special* tiles and not from its
		-- six: special 1 is the still texture and special 2 the flowing
		-- one, which is why water drawn from the ordinary tiles wears its
		-- still texture everywhere. A liquid with no special tile of its
		-- own falls back to the face, which is what resolve_face does.
		local liquid_face = nil
		if group ~= 0 then
			liquid_face = def.drawtype == DRAWTYPE_FLOWINGLIQUID and
					{7, 7, 8, 8, 8, 8} or {7, 7, 7, 7, 7, 7}
		end
		local function resolve_face(d, i, o)
			if liquid_face and i <= 6 then
				return resolve_tile(d, liquid_face[i], o) or
						resolve_tile(d, i, o)
			end
			return resolve_tile(d, i, o)
		end
		local shape, double_sided, masked, solid_base = shapes.for_node(def,
				nil, nil, read_mesh and read_mesh(def) or nil, nil)
		if def.drawtype == DRAWTYPE_AIRLIKE then
			return VOXEL_AIR
		end
		if shape then
			-- Only the tiles the shape uses have to be there: a plant wears
			-- one texture and would be held back by the other five
			local resources = {}
			for _, quad in ipairs(shape) do
				local i = quad.tile
				if not resources[i] then
					-- A shape can name a tile the definition does not give:
					-- a torch has three, a sign one. Luanti falls back to
					-- the first as well.
					resources[i] = resolve_face(def, i, override) or
							resolve_face(def, 1, override)
					if not resources[i] then
						return nil
					end
				end
			end
			-- A shape per mask wears more tiles than the one shape does: a
			-- rail's straight, curve, junction and crossing are four of them
			if masked then
				for m = 0, 19 do
					for _, quad in ipairs(masked[m] or {}) do
						local i = quad.tile
						if not resources[i] then
							resources[i] = resolve_face(def, i, override) or
									resolve_face(def, 1, override)
							if not resources[i] then
								return nil
							end
						end
					end
				end
			end
			-- A shape that keeps its faces needs all six of them; the rest
			-- take whatever the shape's own tiles gave, as Luanti falls back
			-- to the first tile as well
			if solid_base then
				for i = 1, 6 do
					resources[i] = resources[i] or resolve_face(def, i,
							override)
					if not resources[i] then
						return nil
					end
				end
			end
			local first = nil
			for i = 1, 6 do
				first = first or resources[i]
			end
			for i = 1, 6 do
				resources[i] = resources[i] or first
			end
			return add_cube(reg, name or def.name, resources, kind, shape,
					double_sided, nil, group, connect, masked, variants,
					def.alpha_mode == NODEDEF_ALPHAMODE_BLEND, solid_base,
					surface.for_node(def))
		end
		if not kind then
			return nil
		end
		local resources = {}
		for i = 1, 6 do
			resources[i] = resolve_face(def, i, override)
			if not resources[i] then
				return nil
			end
		end
		return add_cube(reg, name or def.name, resources, kind, nil, nil,
				nil, group, connect, nil, variants,
				def.alpha_mode == NODEDEF_ALPHAMODE_BLEND, nil,
				surface.for_node(def))
	end

	-- Builds the registry for a set of node definitions a slice at a time.
	-- What comes back is a function to call with a microsecond budget until
	-- it says it is done; the new registry is swapped in when it is.
	--
	-- A slice at a time because this is two and a half thousand definitions
	-- with a texture expression each, which is more than a second in one go
	-- -- and it happens once the media has arrived, which is after the world
	-- is already on screen. Nothing of the old registry is touched until the
	-- swap, so the world goes on being drawn and meshed from it meanwhile.
	function self:begin_node_definitions(defs, resolve_tile, palette_colors)
		local new_reg = base_registry()
		local map = {
			[CONTENT_AIR] = VOXEL_AIR,
			[CONTENT_IGNORE] = VOXEL_AIR,
		}
		local cubes = 0
		extras_built = 0
		local light_ids = {}
		-- Air's own definition is not among the ones a server sends, so
		-- seed it the way the node map above seeds it: light and sunlight
		-- pass through air, and everything not in here is taken to block
		-- them, which is what a node drawn as the placeholder cube does.
		local light_through = {[CONTENT_AIR] = true}
		local sun_through = {[CONTENT_AIR] = true}
		local collision = {}
		local solid = {}
		local liquid = {}
		local resistance = {}
		local groups = {}
		local post_effect = {}
		local selection = {}
		local pointable = {}
		local new_param2_look = {}

		local connect_group_of = connect_families(defs)

		local function one_definition(id, def)
			-- Which family of connecting nodes this one is in and which it
			-- reaches out to, as the mesher wants them: a number and a bit
			-- per family. On the definition rather than passed along,
			-- because the pair machinery builds voxels from it later too.
			def.connect_group = connect_group_of[id] or 0
			local bits = {}
			for _, to in ipairs(def.connects_to or {}) do
				local to_group = connect_group_of[to]
				if to_group then
					bits[to_group] = true
				end
			end
			-- A rail connects to its own family, which is what its group
			-- number is; nothing lists a rail in a connects_to
			if def.drawtype == DRAWTYPE_RAILLIKE and
					def.connect_group ~= 0 then
				bits[def.connect_group] = true
			end
			local mask = 0
			for bit in pairs(bits) do
				mask = mask + 2 ^ (bit - 1)
			end
			def.connect_mask = mask
			solid[id] = def.walkable
			if def.light_source and def.light_source > 0 then
				light_ids[id] = {level = def.light_source,
						color = light_color(resolve_tile(def, 1))}
			end
			-- Whether light travels through it, which with the light it
			-- gives is what decides the light around it; see
			-- light_changed()
			light_through[id] = def.light_propagates and true or false
			-- And whether the sun goes straight down through it, which is
			-- the one rule that tells glass from air
			sun_through[id] = def.sunlight_propagates and true or false
			-- Luanti's PointabilityType: 0 is not pointable, 1 is, and 2
			-- stops a ray without being pointed at. Those two values are
			-- that way round because they used to be a boolean.
			pointable[id] = def.pointable ~= 0
			-- What a body swims in is the node's liquid_move_physics, as
			-- LocalPlayer has it; a game sets it either way
			liquid[id] = def.liquid_move_physics == true
			resistance[id] = def.move_resistance or 0
			groups[id] = def.groups
			if def.post_effect_color and def.post_effect_color.a > 0 then
				post_effect[id] = def.post_effect_color
			end
			local facing = FACING[def.param_type_2]
			-- A flowing liquid's param2 says how high its surface stands.
			-- The range is how many of the eight levels the liquid spends on
			-- the top of a voxel.
			local liquid_range = def.drawtype == DRAWTYPE_FLOWINGLIQUID and
					(def.liquid_range or 8) or nil
			local variants = build_variants(def, facing, liquid_range,
					read_mesh and read_mesh(def) or nil)
			local voxel = build_voxel(new_reg, def, resolve_tile, nil, nil,
					variants)
			if voxel then
				map[id] = voxel
				if voxel ~= VOXEL_AIR then
					cubes = cubes + 1
				end
			end
			-- Anything left out keeps map_default, the placeholder cube

			-- A definition whose param2 is a palette index is drawn in one
			-- colour per index, and which colour that is is only known once
			-- a voxel with that param2 turns up: see register_pairs(). This
			-- is the one thing param2 says that a variant cannot carry.
			local step = COLOR_STEP[def.param_type_2]
			local colors = nil
			if step and def.palette_name ~= "" and palette_colors then
				colors = palette_colors(def.palette_name)
				if colors and #colors < 2 then
					colors = nil
				end
			end
			-- What the player runs into. Luanti takes the collision box when
			-- the definition has one and the node box otherwise; a voxel
			-- whose boxes are not there at all is a whole cube, which is
			-- what is_solid() says by returning true.
			local cbox = def.collision_box
			if not cbox or #cbox.boxes == 0 then
				cbox = def.node_box
			end
			if def.walkable and cbox and #cbox.boxes > 0 then
				collision[id] = {boxes = cbox.boxes, facing = facing}
			end

			-- What the pointed-node outline goes around: Luanti's selection
			-- box, and the node box when the definition gives none. A node
			-- with neither is a whole voxel, which is what a node not in here
			-- is outlined as.
			local sbox = def.selection_box
			if not sbox or #sbox.boxes == 0 then
				sbox = def.node_box
			end
			if sbox and #sbox.boxes > 0 then
				selection[id] = {boxes = sbox.boxes, facing = facing}
			end

			-- Only a palette needs a voxel per param2 now; the rest of what
			-- param2 says is in the variants
			if voxel and colors then
				new_param2_look[id] = {def = def, step = step,
						colors = colors, variants = variants}
			end
		end

		-- What register_pairs() calls for a pair it has not seen. The voxel
		-- goes into the registry that is current, which is why this is made
		-- here rather than kept as a method: a new set of definitions
		-- replaces the registry and everything built into it.
		build_pair = function(entry, id, p2, key)
			-- Luanti stretches a palette to 256 entries by repeating each
			-- pixel, and indexes that with param2's high bits
			local index = math.floor((p2 - p2 % entry.step) *
					#entry.colors / 256) + 1
			-- Two param2 values that come to the same colour are the same
			-- voxel. What else their param2 says -- a facing, a liquid level
			-- -- is in the variants and does not make a voxel of its own.
			local cache_key = id.."/"..index
			-- Whatever this writes, the map is not the one that was
			-- compiled for the last block
			self.pair_map_version = self.pair_map_version + 1
			local voxel = pair_voxel[cache_key]
			if voxel == nil then
				voxel = build_voxel(self.voxel_reg, entry.def, resolve_tile,
						entry.colors[index],
						entry.def.name.."^"..cache_key,
						entry.variants) or false
				pair_voxel[cache_key] = voxel
			end
			-- false for a pair whose textures are not there: remembered so
			-- that it is not built again for every voxel in every block
			self.pair_map[key] = voxel or false
			if voxel then
				self.pair_count = self.pair_count + 1
			end
		end

		local function commit()
			self.voxel_reg = new_reg
			-- Which voxels give light is decided by the definitions, so what
			-- was worked out from the old ones says nothing
			for _, block in pairs(blocks) do
				block.lights = nil
			end
			-- A fresh atlas registry: the old one holds atlases built for
			-- the old registry's segment ids
			self.atlas_reg = new_atlas_registry()
			self.node_map = map
			self.node_light = light_ids
			self.node_light_through = light_through
			self.node_sun_through = sun_through
			self.node_collision = collision
			self.node_solid = solid
			self.node_liquid = liquid
			self.node_resistance = resistance
			self.node_groups = groups
			self.node_post_effect = post_effect
			self.node_selection = selection
			self.node_pointable = pointable
			-- Everything a param2 meant is decided by these definitions too,
			-- and the pairs were built into the registry that is going away
			self.pair_map = {}
			self.pair_count = 0
			pair_voxel = {}
			param2_look = new_param2_look
			pair_epoch = pair_epoch + 1
			self.pair_map_version = self.pair_map_version + 1
			self.node_map_version = self.node_map_version + 1
			self:invalidate_all()
		end

		local at = nil
		local done = false
		return function(budget_us)
			if done then
				return true, cubes
			end
			local t0 = buildat.get_time_us()
			while true do
				local id, def = next(defs, at)
				if id == nil then
					log:info(extras_built.." voxel types wear a texture "..
							"beyond their six faces")
					done = true
					commit()
					return true, cubes
				end
				at = id
				one_definition(id, def)
				if buildat.get_time_us() - t0 >= budget_us then
					return false, cubes
				end
			end
		end
	end

	-- Everything is out of date; used when what a node id means changes, which
	-- is what arriving node definitions do
	function self:invalidate_all()
		for key, _ in pairs(blocks) do
			mark_dirty(key)
		end
	end

	-- Meshes the blocks nearest the camera first, up to MESH_PER_FRAME of
	-- them, and drops what has gone further away than drop_distance nodes.
	--
	-- drop_distance may be nil, and has to be until the camera is where the
	-- player is: a block the server sends before that is acknowledged as
	-- soon as it arrives, and the server does not send an acknowledged block
	-- again, so dropping it leaves a hole in the world for the rest of the
	-- session -- and the first blocks it sends are the ones around the
	-- player, which is exactly where a hole is worst.
	-- Where and when update() last looked for blocks out of range
	local drop_at = nil
	function self:update(dtime, drop_distance)
		-- A device reset -- a change of screen mode on Windows -- loses
		-- what was filled by hand; the registry puts its Images back
		-- ([BOX_PLAYTEST_3] 1)
		self.atlas_reg:update()
		-- The reflection cube's faces go out one a frame, and `tick` is
		-- what sends them: `update()` above only says that a refresh is
		-- due ([CLIENT_FRAME]). Without this the cube is asked for and
		-- never drawn.
		if sky_cube then
			sky_cube:tick()
		end
		-- Every frame, because easing towards a target is what it is for
		if daylight then
			apply_daylight(dtime)
		end
		local p = camera_node.position
		-- Which lights are the nearest changes as the player walks, but not
		-- so fast that it is worth working out every frame
		if not lights_at or lights_stale or
				(p.x - lights_at[1]) ^ 2 + (p.y - lights_at[2]) ^ 2 +
				(p.z - lights_at[3]) ^ 2 > 4 then
			lights_at = {p.x, p.y, p.z}
			lights_stale = false
			place_lights()
		end
		update_sky_visibility()
		-- Every block's distance, so not every frame: a block leaves the
		-- range when the camera has moved, and one that arrived out of it
		-- can wait a second
		if drop_distance and (not drop_at or
				scene.elapsedTime >= drop_at[4] + 1 or
				(p.x - drop_at[1]) ^ 2 + (p.y - drop_at[2]) ^ 2 +
				(p.z - drop_at[3]) ^ 2 > 4) then
			drop_at = {p.x, p.y, p.z, scene.elapsedTime}
			local limit = drop_distance / BLOCKSIZE
			for key, block in pairs(blocks) do
				local dx = block.x + 0.5 - p.x / BLOCKSIZE
				local dy = block.y + 0.5 - p.y / BLOCKSIZE
				local dz = block.z + 0.5 - p.z / BLOCKSIZE
				if math.sqrt(dx * dx + dy * dy + dz * dz) > limit then
					if block.node then
						scene:RemoveChild(block.node)
					end
					blocks[key] = nil
					if dirty[key] then
						dirty[key] = nil
						dirty_count = dirty_count - 1
					end
				end
			end
		end
		if dirty_count == 0 then
			return 0
		end
		-- The nearest few, rather than a sort of the whole set: the set is
		-- what arrived this frame plus a backlog, and a full sort of it every
		-- frame costs more than the meshing does
		local meshed = 0
		local t0 = buildat.get_time_us()
		self.worst_mesh_us = 0
		local pairs_before = self:pair_voxel_count()
		while meshed < MESH_PER_FRAME do
			if meshed > 0 and buildat.get_time_us() - t0 >= MESH_BUDGET_US then
				break
			end
			local best_key, best_d = nil, nil
			for key, _ in pairs(dirty) do
				local block = blocks[key]
				local dx = block.x * BLOCKSIZE - p.x
				local dy = block.y * BLOCKSIZE - p.y
				local dz = block.z * BLOCKSIZE - p.z
				local d = dx * dx + dy * dy + dz * dz
				if not best_d or d < best_d then
					best_key, best_d = key, d
				end
			end
			if not best_key then
				break
			end
			dirty[best_key] = nil
			dirty_count = dirty_count - 1
			mesh_block(best_key)
			meshed = meshed + 1
		end
		-- What the frame spent handing blocks over, and what it cost beyond
		-- the meshing itself: a voxel pair registered here builds an atlas
		-- segment and uploads a texture, which is a spike of its own
		self.last_frame_mesh_us = buildat.get_time_us() - t0
		self.last_frame_meshed = meshed
		self.last_frame_pairs = self:pair_voxel_count() - pairs_before
		return meshed
	end

	-- Give the screen back to whatever was drawing before, and drop the
	-- blocks' scene nodes. The scene itself goes when nothing points at it.
	function self:close()
		if pbr then
			buildat.set_mesh_bounce(nil)
			buildat.set_mesh_alpha_nibbles(false)
		end
		for key, block in pairs(blocks) do
			if block.node then
				scene:RemoveChild(block.node)
			end
			blocks[key] = nil
		end
		dirty = {}
		dirty_count = 0
		for id, entry in pairs(object_nodes) do
			scene:RemoveChild(entry.node)
			object_nodes[id] = nil
		end
		-- Dropping the viewport rather than replacing it: there is nothing
		-- else to show
		magic.set_preferred_viewports({})
		-- HDR and the render path are the renderer's, not the viewport's, so
		-- a world that has gone has to hand them back or the menu after it is
		-- drawn through a tone curve with nothing to tone map
		magic.renderer.HDRRendering = false
	end

	function self:block_count()
		local n = 0
		for _, _ in pairs(blocks) do
			n = n + 1
		end
		return n
	end

	function self:dirty_count()
		return dirty_count
	end

	-- Whether the blocks within r blocks of a position in nodes are drawn,
	-- and how many are waiting for a mesh: the client's loading panel stays
	-- until they are ([JOIN_WHEN_LOADED]). Not all of them come -- Luanti's
	-- server leaves out the ones it reckons occluded -- so "drawn" is the
	-- player's own block in, none near waiting, and one further out come:
	-- the server sends the nearest first.
	function self:drawn_around(x, y, z, r)
		local bx = math.floor(x / BLOCKSIZE)
		local by = math.floor(y / BLOCKSIZE)
		local bz = math.floor(z / BLOCKSIZE)
		local function far(b)
			return math.max(math.abs(b.x - bx), math.abs(b.y - by),
					math.abs(b.z - bz)) > r
		end
		local waiting = 0
		for key in pairs(dirty) do
			if not far(blocks[key]) then
				waiting = waiting + 1
			end
		end
		if waiting > 0 or not blocks[block_key(bx, by, bz)] then
			return false, waiting
		end
		for _, b in pairs(blocks) do
			if far(b) then
				return true, 0
			end
		end
		return false, 0
	end

	-- Where the camera is and which way it looks, in Luanti's terms: pitch is
	-- degrees positive looking down and yaw is degrees counterclockwise from
	-- +Z seen from above.
	--
	-- Urho3D's pitch is positive looking down too, so that one goes as it
	-- is; its yaw turns the other way round -- clockwise from above, because
	-- it is left-handed where Luanti's rotateXZBy() is right-handed -- so
	-- that one is negated. Getting either sense wrong is not just a mirrored
	-- view: the server sends the blocks it thinks the player can see, so it
	-- would send the ones the player is looking away from.
	-- What set_camera() last placed, for camera_report()
	local camera_placed = nil

	-- Where the camera and the player's own model actually are, as the
	-- frame was drawn: [OVER_SHOULDER]'s open reading, which is that the
	-- model's feet land in the shot as if the camera were nearer than the
	-- setback loop's own last value. Said on demand rather than per frame,
	-- and read beside the shot.
	function self:camera_report()
		-- What set_camera() was last given rather than what the node
		-- reads back: a Quaternion's pitch and yaw are not on the
		-- sandbox's whitelist, and these are the numbers that placed it
		local c = camera_placed or {}
		local out = string.format(
				"camera at %.2f,%.2f,%.2f pitch %.1f yaw %.1f fov %.1f",
				c[1] or 0, c[2] or 0, c[3] or 0, c[4] or 0, c[5] or 0,
				camera and camera.fov or 0)
		local p = {x = c[1] or 0, y = c[2] or 0, z = c[3] or 0}
		local pose = self.self_pose
		if pose then
			local dx, dy, dz = p.x - pose[1], p.y - pose[2], p.z - pose[3]
			out = out .. string.format(
					"; feet %.2f,%.2f,%.2f, %.2f from the eye",
					pose[1], pose[2], pose[3],
					math.sqrt(dx * dx + dy * dy + dz * dz))
		end
		for _, entry in pairs(object_nodes) do
			if entry.is_self_node then
				local q = entry.node.position
				out = out .. string.format("; own node at %.2f,%.2f,%.2f",
						q.x, q.y, q.z)
			end
		end
		return out
	end

	function self:set_camera(x, y, z, pitch, yaw, roll)
		camera_placed = {x, y, z, pitch or 0, yaw or 0}
		camera_node.position = magic.Vector3(x, y, z)
		camera_node.rotation = magic.Quaternion(pitch or 0, -(yaw or 0), roll or 0)
		-- Kept for the light refresh, which only asks for blocks near enough
		-- to be worth a resend; see refresh_wanted()
		camera_at = {x, y, z}
	end

	return self
end

-- Checks build_variants(), which is where what Luanti's param2 means turns
-- into the variants buildat's mesher indexes by the param. init.lua runs it at
-- boot, next to the other self-tests.
function M.self_test()
	-- A cube that faces one of twenty-four directions. Every param2 but the
	-- ones that come to facedir 0 is claimed, and each claimed one gets the
	-- tile order and the turns its direction asks for.
	local vs = build_variants({drawtype = 0}, "facedir", nil)
	assert(vs, "a facedir cube got no variants")
	assert(#vs == 23, "a facedir cube got "..#vs.." variants, not 23")
	local claimed = {}
	local total = 0
	for _, v in ipairs(vs) do
		assert(v.tile_order and v.tile_turns,
				"a facedir variant has no tile order")
		assert(not v.shape, "a facedir cube variant has a shape")
		for _, p2 in ipairs(v.params) do
			assert(not claimed[p2], "param2 "..p2.." is claimed twice")
			claimed[p2] = v
			total = total + 1
		end
	end
	-- Luanti reads a facedir out of param2 as p2 % 32 % 24, so each of the
	-- 24 directions is claimed by the param2 values that come to it, and the
	-- ones that come to 0 are left for the definition itself
	local unclaimed = 0
	for p2 = 0, 255 do
		if shapes.facedir_of("facedir", p2) == 0 then
			assert(not claimed[p2], "param2 "..p2.." faces 0 and is claimed")
			unclaimed = unclaimed + 1
		else
			assert(claimed[p2], "param2 "..p2.." faces "..
					shapes.facedir_of("facedir", p2).." and is unclaimed")
		end
	end
	assert(total + unclaimed == 256,
			total.." + "..unclaimed.." param2 values, not 256")
	-- The tile order is the faces 0...5, permuted; two directions that are
	-- not the same do not get the same one
	local seen = {}
	for _, v in ipairs(vs) do
		local key = table.concat(v.tile_order, ",").."/"..
				table.concat(v.tile_turns, ",")
		assert(not seen[key], "two facedirs come to the same tiles: "..key)
		seen[key] = true
		local used = {}
		for i = 1, 6 do
			local f = v.tile_order[i]
			assert(f >= 0 and f <= 5, "tile order has face "..f)
			assert(not used[f], "tile order wears face "..f.." twice")
			used[f] = true
		end
	end

	-- 4dir is the same thing with four directions, so three variants
	local four = build_variants({drawtype = 0}, "4dir", nil)
	assert(four and #four == 3, "4dir got "..tostring(four and #four).." variants")

	-- A flowing liquid: one variant per level below the top, each a shape
	-- rather than a cube, and the levels rise with param2
	local liq = build_variants({drawtype = 10, liquid_range = 8}, nil, 8)
	assert(liq, "a flowing liquid got no variants")
	local tops = {}
	for _, v in ipairs(liq) do
		assert(v.liquid_top and v.liquid_top < 0.5,
				"a liquid variant stands at "..tostring(v.liquid_top))
		tops[#tops + 1] = v.liquid_top
	end
	assert(#liq >= 7, "a flowing liquid got "..#liq.." levels")
	for i = 2, #tops do
		assert(tops[i] > tops[i - 1],
				"liquid levels are not in order: "..tops[i - 1].." then "..
				tops[i])
	end

	-- Nothing to say about param2, nothing built
	assert(build_variants({drawtype = 0}, nil, nil) == nil,
			"a definition with no param2 meaning got variants")
end

M.BLOCKSIZE = BLOCKSIZE
M.VOXEL_AIR = VOXEL_AIR
M.VOXEL_PLACEHOLDER = VOXEL_PLACEHOLDER

return M
-- vim: set noet ts=4 sw=4:
